const std = @import("std");

const mime_list = [_]struct { ext: []const []const u8, mime: []const u8 }{
    .{ .ext = &.{"aac"}, .mime = "audio/aac" },
    .{ .ext = &.{"avif"}, .mime = "image/avif" },
    .{ .ext = &.{"avi"}, .mime = "video/x-msvideo" },
    .{ .ext = &.{"bin"}, .mime = "application/octet-stream" },
    .{ .ext = &.{"bmp"}, .mime = "image/bmp" },
    .{ .ext = &.{"bz"}, .mime = "application/x-bzip" },
    .{ .ext = &.{"bz2"}, .mime = "application/x-bzip2" },
    .{ .ext = &.{"css"}, .mime = "text/css" },
    .{ .ext = &.{"csv"}, .mime = "text/csv" },
    .{ .ext = &.{"eot"}, .mime = "application/vnd.ms-fontobject" },
    .{ .ext = &.{"gz"}, .mime = "application/gzip" },
    .{ .ext = &.{"gif"}, .mime = "image/gif" },
    .{ .ext = &.{ "htm", "html" }, .mime = "text/html" },
    .{ .ext = &.{"ico"}, .mime = "image/vnd.microsoft.icon" },
    .{ .ext = &.{"ics"}, .mime = "text/calendar" },
    .{ .ext = &.{"jar"}, .mime = "application/java-archive" },
    .{ .ext = &.{ "jpeg", "jpg" }, .mime = "image/jpeg" },
    .{ .ext = &.{"js"}, .mime = "text/javascript" },
    .{ .ext = &.{"json"}, .mime = "application/json" },
    .{ .ext = &.{"md"}, .mime = "text/x-markdown" },
    .{ .ext = &.{"yml"}, .mime = "application/x-yaml" },
    .{ .ext = &.{"toml"}, .mime = "application/x-toml" },
    .{ .ext = &.{"mjs"}, .mime = "text/javascript" },
    .{ .ext = &.{"mp3"}, .mime = "audio/mpeg" },
    .{ .ext = &.{"mp4"}, .mime = "video/mp4" },
    .{ .ext = &.{"mpeg"}, .mime = "video/mpeg" },
    .{ .ext = &.{"oga"}, .mime = "audio/ogg" },
    .{ .ext = &.{"ogv"}, .mime = "video/ogg" },
    .{ .ext = &.{"ogx"}, .mime = "application/ogg" },
    .{ .ext = &.{"opus"}, .mime = "audio/opus" },
    .{ .ext = &.{"otf"}, .mime = "font/otf" },
    .{ .ext = &.{"png"}, .mime = "image/png" },
    .{ .ext = &.{"pdf"}, .mime = "application/pdf" },
    .{ .ext = &.{"rar"}, .mime = "application/vnd.rar" },
    .{ .ext = &.{"rtf"}, .mime = "application/rtf" },
    .{ .ext = &.{"sh"}, .mime = "application/x-sh" },
    .{ .ext = &.{"svg"}, .mime = "image/svg+xml" },
    .{ .ext = &.{"tar"}, .mime = "application/x-tar" },
    .{ .ext = &.{ "tif", "tiff" }, .mime = "image/tiff" },
    .{ .ext = &.{"ts"}, .mime = "video/mp2t" },
    .{ .ext = &.{"ttf"}, .mime = "font/ttf" },
    .{ .ext = &.{"txt"}, .mime = "text/plain" },
    .{ .ext = &.{"wav"}, .mime = "audio/wav" },
    .{ .ext = &.{"weba"}, .mime = "audio/webm" },
    .{ .ext = &.{"webm"}, .mime = "video/webm" },
    .{ .ext = &.{"webp"}, .mime = "image/webp" },
    .{ .ext = &.{"woff"}, .mime = "font/woff" },
    .{ .ext = &.{"woff2"}, .mime = "font/woff2" },
    .{ .ext = &.{"xhtml"}, .mime = "application/xhtml+xml" },
    .{ .ext = &.{"xml"}, .mime = "application/xml" },
    .{ .ext = &.{"zip"}, .mime = "application/zip" },
    .{ .ext = &.{"7z"}, .mime = "application/x-7z-compressed" },
    .{ .ext = &.{"wasm"}, .mime = "application/wasm" },
    .{ .ext = &.{"zig"}, .mime = "application/x-zig" },
};

pub fn getMime(ext: []const u8) ?[]const u8 {
    for (mime_list) |entry| {
        for (entry.ext) |ext_entry| {
            if (std.mem.eql(u8, ext, ext_entry))
                return entry.mime;
        }
    }
    return null;
}
