const std = @import("std");
const mime = @import("mime.zig");
const net = std.net;
const mem = std.mem;
const fs = std.fs;
const Step = std.build.Step;
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;

const index_unformatted = @embedFile("template/index.html");
const default_mime = "text/plain";
const max_file_size = 100 * 1024 * 1024 * 1024; // 100MB
const colors = struct {
    pub const reset = "\x1b[0m";
    pub const red = "\x1b[31m";
    pub const yellow = "\x1b[33m";
    pub const cyan = "\x1b[36m";
};

pub const Options = struct {
    root_dir: []const u8,
    watch_paths: []const []const u8 = &.{},
    serve_paths: []const []const u8 = &.{},
    listen_address: net.Address = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 8080),
};

pub fn serve(step: *LibExeObjStep, options: Options) fs.File.OpenError!*Wasmserve {
    const self = step.builder.allocator.create(Wasmserve) catch unreachable;
    self.* = Wasmserve{
        .step = Step.init(.run, "wasmserve", step.builder.allocator, Wasmserve.make),
        .cwd = try fs.cwd().openDir(options.root_dir, .{}),
        // crashes if `step.builder.zig_exe` used instead `zig`
        .build_proc = std.ChildProcess.init(&.{ "zig", "build", "install" }, step.builder.allocator),
        .exe_step = step,
        .allocator = step.builder.allocator,
        .address = options.listen_address,
        .root_dir = options.root_dir,
        .watch_paths = options.watch_paths,
        .serve_paths = options.serve_paths,
        .stream_server = std.net.StreamServer.init(.{ .reuse_address = true }),
        .mtimes = std.AutoHashMap(fs.File.INode, i128).init(step.builder.allocator),
        .server_thread = undefined,
        .conn_buf = undefined,
    };
    self.build_proc.cwd = self.root_dir;
    self.build_proc.stdout = std.io.getStdOut();
    self.build_proc.stderr = std.io.getStdErr();
    self.build_proc.term = .{ .Unknown = 0 };
    return self;
}

const Wasmserve = struct {
    step: Step,
    exe_step: *LibExeObjStep,
    allocator: mem.Allocator,
    cwd: fs.Dir,
    build_proc: std.ChildProcess,
    server_thread: std.Thread,
    address: net.Address,
    stream_server: net.StreamServer,
    mtimes: std.AutoHashMap(fs.File.INode, i128),
    conn_buf: [1024]u8,
    root_dir: []const u8,
    watch_paths: []const []const u8,
    serve_paths: []const []const u8,

    pub fn make(step: *Step) !void {
        const self = @fieldParentPtr(Wasmserve, "step", step);

        try self.compile();
        _ = try self.build_proc.wait();
        std.debug.assert(mem.eql(u8, fs.path.extension(self.exe_step.out_filename), ".wasm"));
        self.server_thread = try std.Thread.spawn(.{}, runServer, .{self});
        try self.watch();
    }

    fn runServer(self: *Wasmserve) !void {
        try self.stream_server.listen(self.address);
        var buf = @as([45]u8, undefined);
        var fbs = std.io.fixedBufferStream(&buf);
        try self.address.format(undefined, undefined, fbs.writer());
        std.log.info("Started listening at " ++ colors.cyan ++ "http://{s}" ++ colors.reset ++ "...", .{fbs.getWritten()});
        while (true) try self.accept();
    }

    fn accept(self: *Wasmserve) !void {
        const conn = try self.stream_server.accept();
        defer conn.stream.close();
        const reader = conn.stream.reader();
        const writer = conn.stream.writer();

        const first_line = reader.readUntilDelimiter(&self.conn_buf, '\n') catch {
            try self.respondError(writer, 400, "Bad Request");
            return;
        };
        if (first_line.len == 0) {
            try self.respondError(writer, 400, "Bad Request");
            return;
        }
        var first_line_iter = mem.split(u8, first_line, " ");
        _ = first_line_iter.next(); // skip method
        if (first_line_iter.next()) |uri| {
            const url = dropFragment(uri);
            const url_path = try self.normalizePath(url);
            defer self.allocator.free(url_path);

            const wasm_file_path = try self.normalizePath(self.exe_step.out_filename);
            defer self.allocator.free(wasm_file_path);
            if (mem.eql(u8, url_path, wasm_file_path)) {
                const wasm_file_path_real = try fs.path.join(self.allocator, &.{ "zig-out/lib", self.exe_step.out_filename });
                defer self.allocator.free(wasm_file_path_real);
                try self.respondFile(writer, wasm_file_path_real);
                return;
            }

            for (self.serve_paths) |serve_path| {
                const serve_path_norm = try self.normalizePath(serve_path);
                defer self.allocator.free(serve_path_norm);

                var dir = self.cwd.openIterableDir(serve_path_norm, .{}) catch {
                    if ((url_path.len == 0 and mem.eql(u8, serve_path_norm, "index.html")) or
                        mem.eql(u8, serve_path_norm, url_path))
                    {
                        try self.respondFile(writer, serve_path_norm);
                        return;
                    }
                    continue;
                };
                defer dir.close();
                var walker = try dir.walk(self.allocator);
                defer walker.deinit();
                while (try walker.next()) |walk_entry| {
                    if (walk_entry.kind != .File) continue;
                    const file_path = try fs.path.join(self.allocator, &.{ serve_path_norm, walk_entry.path });
                    defer self.allocator.free(file_path);

                    if (mem.eql(u8, file_path, url_path)) {
                        try self.respondFile(writer, file_path);
                        return;
                    }
                }
            }

            if (url_path.len == 0) {
                const index_formatted = try std.fmt.allocPrint(self.allocator, index_unformatted, .{ self.exe_step.name, self.exe_step.out_filename });
                try self.respond(writer, "text/html", index_formatted);
                return;
            }

            try self.respondError(writer, 404, "Not Found");
        } else {
            try self.respondError(writer, 400, "Bad Request");
            return;
        }
    }

    fn normalizePath(self: Wasmserve, path: []const u8) ![]const u8 {
        const p_joined = try fs.path.join(self.allocator, &.{ ".", path });
        defer self.allocator.free(p_joined);
        const p_rel = try fs.path.relative(self.allocator, self.root_dir, p_joined);
        return p_rel;
    }

    fn respond(self: Wasmserve, writer: net.Stream.Writer, content_type: []const u8, body: []const u8) !void {
        const resp = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {d}\r\nContent-Type: {s}\r\n\r\n{s}",
            .{ body.len, content_type, body },
        );
        defer self.allocator.free(resp);
        try writer.writeAll(resp);
    }

    fn respondFile(self: Wasmserve, writer: net.Stream.Writer, path: []const u8) !void {
        const data = try self.cwd.readFileAlloc(self.allocator, path, max_file_size);
        defer self.allocator.free(data);
        const file_mime = blk: {
            const ext = fs.path.extension(path);
            if (ext.len < 2)
                break :blk "text/plain";
            const the_mime = mime.getMime(ext[1..]) orelse break :blk "text/plain";
            break :blk the_mime;
        };
        try self.respond(writer, file_mime, data);
    }

    fn respondError(self: Wasmserve, writer: net.Stream.Writer, code: u32, desc: []const u8) !void {
        const resp = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 {d} {s}\r\nConnection: close\r\nContent-Length: {d}\r\nContent-Type: text/html\r\n\r\n<!DOCTYPE html><html><body><h1>{s}</h1></body></html>",
            .{ code, desc, desc.len + 50, desc },
        );
        defer self.allocator.free(resp);
        try writer.writeAll(resp);
    }

    fn watch(self: *Wasmserve) !void {
        timer_loop: while (true) : (std.time.sleep(100 * 1000 * 1000)) { // 100ms
            for (self.watch_paths) |unvalidated_path| {
                const path = try self.normalizePath(unvalidated_path);
                defer self.allocator.free(path);
                var dir = self.cwd.openIterableDir(path, .{}) catch {
                    if (try self.checkForUpdate(path)) continue :timer_loop;
                    continue;
                };
                defer dir.close();
                var walker = try dir.walk(self.allocator);
                defer walker.deinit();
                while (try walker.next()) |walk_entry| {
                    if (walk_entry.kind != .File) continue;
                    if (try self.checkForUpdate(walk_entry.path)) continue :timer_loop;
                }
            }
        }
    }

    fn checkForUpdate(self: *Wasmserve, path: []const u8) !bool {
        const stat = try self.cwd.statFile(path);
        const entry = try self.mtimes.getOrPut(stat.inode);
        if (entry.found_existing and stat.mtime > entry.value_ptr.*) {
            std.log.info(colors.yellow ++ "{s}" ++ colors.reset ++ " updated", .{path});
            try self.compile();
            entry.value_ptr.* = stat.mtime;
            return true;
        }
        entry.value_ptr.* = stat.mtime;
        return false;
    }

    fn compile(self: *Wasmserve) !void {
        std.log.info("Compiling...", .{});
        if (self.build_proc.term == null)
            _ = try self.build_proc.kill();
        try self.build_proc.spawn();
        self.build_proc.term = null;
    }
};

fn dropFragment(input: []const u8) []const u8 {
    for (input) |c, i|
        if (c == '?' or c == '#')
            return input[0..i];

    return input;
}

fn thisDir() []const u8 {
    return fs.path.dirname(@src().file) orelse ".";
}
