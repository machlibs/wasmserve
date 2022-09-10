const std = @import("std");
const net = std.net;
const mem = std.mem;
const fs = std.fs;
const Step = std.build.Step;
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;

pub fn serve(step: *LibExeObjStep, watch_paths: []const []const u8, root_dir: ?[]const u8, listen_address: ?net.Address, load_instance_fn: ?[]const u8) fs.File.OpenError!*Wasmserve {
    const self = step.builder.allocator.create(Wasmserve) catch unreachable;
    self.* = Wasmserve{
        .step = Step.init(.run, "wasmserve", step.builder.allocator, Wasmserve.make),
        .exe_step = step,
        .allocator = step.builder.allocator,
        .address = listen_address orelse net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 8080),
        .root_dir = root_dir orelse thisDir(),
        .load_instance_fn = load_instance_fn orelse default_load_fn,
        .watch_paths = watch_paths,
        .build_proc = std.ChildProcess.init(&.{ "zig", "build", "install" }, step.builder.allocator),
        .server_thread = undefined,
        .stream_server = undefined,
        .conn_buf = undefined,
        .cwd = try fs.cwd().openDir(root_dir orelse thisDir(), .{}),
    };
    self.build_proc.term = .{ .Unknown = 0 };
    self.build_proc.stdout = std.io.getStdOut();
    self.build_proc.stderr = std.io.getStdErr();
    return self;
}

const Wasmserve = struct {
    step: Step,
    exe_step: *LibExeObjStep,
    allocator: mem.Allocator,
    address: net.Address,
    watch_paths: []const []const u8,
    root_dir: []const u8,
    load_instance_fn: []const u8,
    build_proc: std.ChildProcess,
    server_thread: std.Thread,
    stream_server: net.StreamServer,
    conn_buf: [1024]u8,
    cwd: fs.Dir,

    pub fn make(step: *Step) !void {
        const self = @fieldParentPtr(Wasmserve, "step", step);
        try self.compile();
        std.debug.assert(mem.eql(u8, fs.path.extension(self.exe_step.out_filename), ".wasm"));
        try self.fillTemplate();
        self.server_thread = try std.Thread.spawn(.{}, runServer, .{self});
        defer self.server_thread.detach();
        try self.watch();
    }

    fn fillTemplate(self: Wasmserve) !void {
        var templ_file = try self.cwd.openFile(comptime thisDir() ++ "/template/index.html", .{});
        defer templ_file.close();
        var data = try templ_file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(data);
        var out0 = try mem.replaceOwned(u8, self.allocator, data, "{0}", self.exe_step.name);
        defer self.allocator.free(out0);
        var out1 = try mem.replaceOwned(u8, self.allocator, out0, "{1}", self.load_instance_fn);
        defer self.allocator.free(out1);
        var out2 = try mem.replaceOwned(u8, self.allocator, out1, "{2}", self.exe_step.out_filename);
        defer self.allocator.free(out2);

        const www_dir_path = try fs.path.join(self.allocator, &.{ self.root_dir, "zig-out/www" });
        defer self.allocator.free(www_dir_path);
        try self.cwd.makePath(www_dir_path);
        var www_dir = try self.cwd.openDir(www_dir_path, .{});
        defer www_dir.close();

        const www_index_path = try fs.path.join(self.allocator, &.{ www_dir_path, "index.html" });
        defer self.allocator.free(www_index_path);

        var out_file = try self.cwd.createFile(www_index_path, .{});
        defer out_file.close();
        try out_file.writeAll(out2);

        const bin_file_path = try fs.path.join(self.allocator, &.{ self.root_dir, "zig-out/lib", self.exe_step.out_filename });
        defer self.allocator.free(bin_file_path);
        try self.cwd.copyFile(bin_file_path, www_dir, self.exe_step.out_filename, .{});
    }

    fn runServer(self: *Wasmserve) !void {
        self.stream_server = std.net.StreamServer.init(.{ .reuse_address = true });
        defer self.stream_server.deinit();
        try self.stream_server.listen(self.address);

        while (true) {
            try self.accept();
        }
    }

    fn accept(self: *Wasmserve) !void {
        const conn = try self.stream_server.accept();
        defer conn.stream.close();
        const reader = conn.stream.reader();
        const writer = conn.stream.writer();

        // read first line
        const first_line = (try reader.readUntilDelimiterOrEof(&self.conn_buf, '\n')).?;
        if (first_line.len == 0) {
            try self.writeError(writer, 400, "Bad Request");
            return;
        }
        var first_line_iter = mem.split(u8, first_line, " ");
        _ = first_line_iter.next(); // skip method
        if (first_line_iter.next()) |uri| {
            const abs_path = try fs.path.join(self.allocator, &.{ self.root_dir, uri });
            defer self.allocator.free(abs_path);

            const relative_path = try fs.path.relative(self.allocator, self.root_dir, abs_path);
            defer self.allocator.free(relative_path);

            const www_dir_path = try fs.path.join(self.allocator, &.{ self.root_dir, "zig-out/www" });
            defer self.allocator.free(www_dir_path);
            var www_dir = try self.cwd.openIterableDir(www_dir_path, .{});
            defer www_dir.close();

            var walker = try www_dir.walk(self.allocator);
            defer walker.deinit();

            while (try walker.next()) |e| {
                if (e.kind == .File and mem.eql(u8, relative_path, e.path)) {
                    const file = try www_dir.dir.readFileAlloc(self.allocator, relative_path, 1024 * 1024 * 1024);
                    defer self.allocator.free(file);
                    try self.respond(writer, "text/html", file);
                    return;
                }
            }
            try self.writeError(writer, 404, "Not Found");
        } else {
            try self.writeError(writer, 400, "Bad Request");
            return;
        }
    }

    fn respond(self: Wasmserve, writer: net.Stream.Writer, content_type: []const u8, body: []const u8) !void {
        var resp = std.ArrayList(u8).init(self.allocator);
        defer resp.deinit();
        const headers = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {d}\r\nContent-Type: {s}\r\n\r\n",
            .{ body.len, content_type },
        );
        defer self.allocator.free(headers);
        try resp.appendSlice(headers);
        try resp.appendSlice(body);
        try writer.writeAll(resp.items);
    }

    fn writeError(self: Wasmserve, writer: net.Stream.Writer, code: u32, desc: []const u8) !void {
        const resp = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 {d} {s}\r\nConnection: close\r\nContent-Length: {d}\r\nContent-Type: text/html\r\n\r\n<h1>{s}</h1>",
            .{ code, desc, desc.len + 9, desc },
        );
        defer self.allocator.free(resp);
        try writer.writeAll(resp);
    }

    fn watch(self: *Wasmserve) !void {
        var mtimes = std.AutoHashMap(fs.File.INode, i128).init(self.allocator);
        defer mtimes.deinit();

        while (true) : (std.time.sleep(100 * 1000 * 1000)) {
            for (self.watch_paths) |unvalidated_path| {
                const path = try fs.path.resolve(self.allocator, &.{ self.root_dir, unvalidated_path });
                defer self.allocator.free(path);
                // std.debug.print("{s}\n", .{path});
                var dir = self.cwd.openIterableDir(path, .{}) catch {
                    var file = try self.cwd.openFile(path, .{});
                    defer file.close();
                    const stat = try file.stat();
                    const entry = try mtimes.getOrPut(stat.inode);
                    if (entry.found_existing and stat.mtime > entry.value_ptr.*) {
                        try self.compile();
                    }
                    entry.value_ptr.* = stat.mtime;
                    continue;
                };
                defer dir.close();
                var walker = try dir.walk(self.allocator);
                while (try walker.next()) |walk_entry| {
                    if (walk_entry.kind != .File) continue;

                    var file = try self.cwd.openFile(walk_entry.path, .{});
                    defer file.close();
                    const stat = try file.stat();
                    const entry = try mtimes.getOrPut(stat.inode);
                    if (entry.found_existing and stat.mtime > entry.value_ptr.*) {
                        try self.compile();
                    }
                    entry.value_ptr.* = stat.mtime;
                }
            }
        }
    }

    fn compile(self: *Wasmserve) !void {
        _ = try self.build_proc.spawnAndWait();
    }
};

fn thisDir() []const u8 {
    return fs.path.dirname(@src().file) orelse ".";
}

const default_load_fn =
    \\function load(_instance) {}
    \\
;
