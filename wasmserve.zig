const builtin = @import("builtin");
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
const esc = struct {
    pub const reset = "\x1b[0m";
    pub const underline = "\x1b[4m";
    pub const red = "\x1b[31m";
    pub const yellow = "\x1b[33m";
    pub const cyan = "\x1b[36m";
};

pub const Options = struct {
    watch_paths: []const []const u8 = &.{},
    serve_paths: []const []const u8 = &.{},
    listen_address: net.Address = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 8080),
};

pub fn serve(step: *LibExeObjStep, root_dir: []const u8, options: Options) !*Wasmserve {
    const self = step.builder.allocator.create(Wasmserve) catch unreachable;
    self.* = Wasmserve{
        .step = Step.init(.run, "wasmserve", step.builder.allocator, Wasmserve.make),
        .exe_step = step,
        .allocator = step.builder.allocator,
        .cwd = try fs.cwd().openDir(root_dir, .{}),
        .root_dir = root_dir,
        .server_thread = undefined,
        .address = options.listen_address,
        .subscriber = null,
        .serve_paths = options.serve_paths,
        .listener = net.StreamServer.init(.{ .reuse_address = true }),
        // TODO: crashes if step.builder.zig_exe used instead "zig"
        .build_proc = std.ChildProcess.init(&.{ "zig", "build", "install" }, step.builder.allocator),
        .watch_paths = options.watch_paths,
        .mtimes = std.AutoHashMap(fs.File.INode, i128).init(step.builder.allocator),
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
    root_dir: []const u8,
    server_thread: std.Thread,
    listener: net.StreamServer,
    address: net.Address,
    subscriber: ?*const net.Stream,
    serve_paths: []const []const u8,
    build_proc: std.ChildProcess,
    watch_paths: []const []const u8,
    mtimes: std.AutoHashMap(fs.File.INode, i128),

    const NotifyMessage = enum {
        reload,
        close,
    };

    pub fn make(step: *Step) !void {
        const self = @fieldParentPtr(Wasmserve, "step", step);

        try self.compile();
        _ = try self.build_proc.wait();
        std.debug.assert(mem.eql(u8, fs.path.extension(self.exe_step.out_filename), ".wasm"));
        self.server_thread = try std.Thread.spawn(.{}, runServer, .{self});
        try self.watch();
    }

    fn runServer(self: *Wasmserve) !void {
        try self.listener.listen(self.address);

        var addr_buf = @as([45]u8, undefined);
        var fbs = std.io.fixedBufferStream(&addr_buf);
        try self.address.format(undefined, undefined, fbs.writer());
        std.log.info("Started listening at " ++ esc.cyan ++ esc.underline ++ "http://{s}" ++ esc.reset ++ "...", .{fbs.getWritten()});

        while (true) {
            self.accept() catch |err| {
                std.log.err(esc.red ++ "{s}" ++ esc.reset ++ " -> while accepting connections", .{@errorName(err)});
            };
        }
    }

    fn accept(self: *Wasmserve) !void {
        const conn = try self.listener.accept();

        var conn_buf: [2048]u8 = undefined;
        const first_line = conn.stream.reader().readUntilDelimiter(&conn_buf, '\n') catch |err| {
            switch (err) {
                error.StreamTooLong => try self.respondError(conn.stream, 414, "Too Long Request"),
                else => try self.respondError(conn.stream, 400, "Bad Request"),
            }
            return;
        };

        var first_line_iter = mem.split(u8, first_line, " ");
        _ = first_line_iter.next(); // skip method
        if (first_line_iter.next()) |uri| {
            const url = dropFragment(uri);

            if (mem.eql(u8, url, "/notify")) {
                _ = try conn.stream.write("HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n");
                self.subscriber = &conn.stream;
                return;
            }

            const url_path = try self.normalizePath(url);
            defer self.allocator.free(url_path);
            if (try self.researchPath(url_path)) |file_path| {
                defer self.allocator.free(file_path);
                try self.respondFile(conn.stream, file_path);
                return;
            } else if (url_path.len == 0) {
                const index_formatted = try std.fmt.allocPrint(self.allocator, index_unformatted, .{ self.exe_step.name, self.exe_step.out_filename });
                defer self.allocator.free(index_formatted);
                try self.respond(conn.stream, "text/html", index_formatted);
                return;
            }

            try self.respondError(conn.stream, 404, "Not Found");
        } else {
            try self.respondError(conn.stream, 400, "Bad Request");
        }
    }

    fn respondFile(self: Wasmserve, conn: net.Stream, path: []const u8) !void {
        const data = try self.cwd.readFileAlloc(self.allocator, path, max_file_size);
        defer self.allocator.free(data);
        const file_mime = blk: {
            const ext = fs.path.extension(path);
            if (ext.len < 2)
                break :blk "text/plain";
            const the_mime = mime.getMime(ext[1..]) orelse break :blk "text/plain";
            break :blk the_mime;
        };
        try self.respond(conn, file_mime, data);
    }

    fn respond(self: Wasmserve, conn: net.Stream, content_type: []const u8, body: []const u8) !void {
        const resp = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {d}\r\nContent-Type: {s}\r\n\r\n{s}",
            .{ body.len, content_type, body },
        );
        defer self.allocator.free(resp);
        _ = try conn.write(resp);
        conn.close();
    }

    fn respondError(self: Wasmserve, conn: net.Stream, code: u32, desc: []const u8) !void {
        const resp = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 {d} {s}\r\nConnection: close\r\nContent-Length: {d}\r\nContent-Type: text/html\r\n\r\n<!DOCTYPE html><html><body><h1>{s}</h1></body></html>",
            .{ code, desc, desc.len + 50, desc },
        );
        defer self.allocator.free(resp);
        _ = try conn.write(resp);
        conn.close();
    }

    fn researchPath(self: Wasmserve, path: []const u8) !?[]const u8 {
        const wasm_file_path = try self.normalizePath(self.exe_step.out_filename);
        defer self.allocator.free(wasm_file_path);
        if (mem.eql(u8, path, wasm_file_path))
            return try fs.path.join(self.allocator, &.{ "zig-out/lib", self.exe_step.out_filename });

        for (self.serve_paths) |serve_path| {
            const serve_path_norm = try self.normalizePath(serve_path);
            var dir = self.cwd.openIterableDir(serve_path_norm, .{}) catch {
                if (mem.eql(u8, serve_path_norm, path) or
                    (path.len == 0 and mem.eql(u8, serve_path_norm, "index.html")))
                    return serve_path_norm;

                self.allocator.free(serve_path_norm);
                continue;
            };
            defer self.allocator.free(serve_path_norm);
            defer dir.close();
            var walker = try dir.walk(self.allocator);
            defer walker.deinit();
            while (try walker.next()) |walk_entry| {
                if (walk_entry.kind != .File) continue;
                const file_path = try fs.path.join(self.allocator, &.{ serve_path_norm, walk_entry.path });
                if (mem.eql(u8, file_path, path))
                    return file_path;
                defer self.allocator.free(file_path);
            }
        }
        return null;
    }

    fn watch(self: *Wasmserve) !void {
        timer_loop: while (true) : (std.time.sleep(100 * 1000 * 1000)) { // 100ms
            for (self.watch_paths) |path| {
                const path_norm = try self.normalizePath(path);
                defer self.allocator.free(path_norm);
                var dir = self.cwd.openIterableDir(path_norm, .{}) catch {
                    if (try self.checkForUpdate(path_norm)) continue :timer_loop;
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

    fn normalizePath(self: Wasmserve, path: []const u8) ![]const u8 {
        const p_joined = try fs.path.join(self.allocator, &.{ ".", path });
        defer self.allocator.free(p_joined);
        const p_rel = try fs.path.relative(self.allocator, self.root_dir, p_joined);
        return p_rel;
    }

    fn checkForUpdate(self: *Wasmserve, path: []const u8) !bool {
        const stat = try self.cwd.statFile(path);
        const entry = try self.mtimes.getOrPut(stat.inode);
        if (entry.found_existing and stat.mtime > entry.value_ptr.*) {
            std.log.info(esc.yellow ++ esc.underline ++ "{s}" ++ esc.reset ++ " updated", .{path});
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
        try self.notifyClient(.reload);
        self.build_proc.term = null;
    }

    fn notifyClient(self: *Wasmserve, msg: NotifyMessage) !void {
        if (self.subscriber) |s|
            _ = s.writer().print("data: {s}\n\n", .{@tagName(msg)}) catch {};
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
