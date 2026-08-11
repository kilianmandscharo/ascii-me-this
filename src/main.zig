const std = @import("std");
const c = @import("c");

const chunk_size = 10;
const characters = [_]u8{ '.', ':', 'c', 'o', 'P', 'O', '@', '$' };

const GAUSSIAN = &.{
    &.{ 1, 4, 7, 4, 1 },
    &.{ 4, 16, 26, 16, 4 },
    &.{ 7, 26, 41, 26, 7 },
    &.{ 4, 16, 26, 16, 4 },
    &.{ 1, 4, 7, 4, 1 },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    std.debug.print("{s}\n", .{args[0]});

    if (args.len < 3) {
        std.debug.print("usage: {s} <input_path> <output_path>\n", .{args[0]});
        std.process.exit(1);
    }

    const input_path = args[1];
    const output_path = args[2];

    var input_image = try Image.fromPath(input_path);
    defer input_image.deinit();

    var output_image = try Image.fromRgb(arena, &input_image);
    defer output_image.deinit();

    var blurred_image = try output_image.applyKernel(arena, GAUSSIAN);
    defer blurred_image.deinit();

    try blurred_image.write(output_path);

    // var img = try Image.fromRgb(arena, pixels, width, height, channels);

    // try img.write(output_path);

    // const n_cores = try std.Thread.getCpuCount();

    // const number_of_rows: usize = @intCast(@divTrunc((height + chunk_size - 1), chunk_size));
    // const number_of_cols: usize = @intCast(@divTrunc((width + chunk_size - 1), chunk_size));

    // const glyph_map = try createGlyphMap(io, arena);
    //
    // const thread_chunk_size: usize = @intCast(@divTrunc((number_of_rows + n_cores - 1), n_cores));
    // var threads: std.ArrayList(std.Thread) = .empty;
    //
    // for (0..n_cores) |core| {
    //     const row_start = core * thread_chunk_size;
    //     if (row_start > number_of_rows) continue;
    //
    //     const row_end = if (row_start + thread_chunk_size < number_of_rows) row_start + thread_chunk_size else number_of_rows;
    //
    //     const thread = try std.Thread.spawn(.{}, processChunk, .{
    //         img.out_buffer,
    //         pixels,
    //         height,
    //         width,
    //         channels,
    //         glyph_map,
    //         row_start,
    //         row_end,
    //         number_of_cols,
    //     });
    //
    //     try threads.append(arena, thread);
    // }
    //
    // for (threads.items) |t| t.join();
    //
    // const result = c.stbi_write_jpg(
    //     output_path,
    //     width_from_image,
    //     height_from_image,
    //     1,
    //     img.buf.ptr,
    //     90,
    // );
    //
    // if (result == 0) {
    //     std.debug.print("Failed to write image\n", .{});
    // } else {
    //     std.debug.print("Image written successfully\n", .{});
    // }
}

fn processChunk(
    out_buffer: []u8,
    pixels: [*c]u8,
    height: usize,
    width: usize,
    channels: usize,
    glyph_map: GlyphMap,
    row_start: usize,
    row_end: usize,
    number_of_cols: usize,
) !void {
    for (row_start..row_end) |row_chunk| {
        for (0..number_of_cols) |col_chunk| {
            var total: u32 = 0;
            var count: u32 = 0;

            for (0..chunk_size) |i| {
                for (0..chunk_size) |j| {
                    const y = row_chunk * chunk_size + i;
                    const x = col_chunk * chunk_size + j;

                    if (y >= height or x >= width) {
                        continue;
                    }

                    const offset = (y * width + x) * channels;
                    const r = pixels[offset];
                    const g = pixels[offset + 1];
                    const b = pixels[offset + 2];
                    total += (@as(u16, 77) * @as(u16, r) + @as(u16, 150) * @as(u16, g) + @as(u16, 29) * @as(u16, b)) >> 8;
                    count += 1;
                }
            }

            const intensity: u8 = @intCast(total / count);
            const char_index: usize = (@as(u16, intensity) * @as(u16, characters.len)) >> 8;
            const char = characters[char_index];
            const glyph = glyph_map.get(char) orelse unreachable;

            for (0..glyph.height) |y| {
                for (0..glyph.width) |x| {
                    const src_offset = y * glyph.width + x;
                    const dst_x = x + col_chunk * chunk_size;
                    const dst_y = y + row_chunk * chunk_size;
                    if (dst_x < width and dst_y < height) {
                        out_buffer[dst_y * width + dst_x] = glyph.data[src_offset];
                    }
                }
            }
        }
    }
}

const Image = struct {
    buf: []u8,
    width: usize,
    height: usize,
    channels: usize,
    is_stbi_src: bool = false,

    const FACTOR_RED: u16 = 77;
    const FACTOR_GREEN: u16 = 150;
    const FACTOR_BLUE: u16 = 29;

    fn deinit(self: *Image) void {
        if (self.is_stbi_src) {
            c.stbi_image_free(self.buf.ptr);
        }
    }

    fn fromImg(arena: std.mem.Allocator, src: *Image) !Image {
        const out_buffer = try arena.alloc(u8, src.width * src.height);
        for (out_buffer) |*p| p.* = 0;

        return .{
            .buf = out_buffer,
            .width = src.width,
            .height = src.height,
            .channels = src.channels,
        };
    }

    fn fromPath(path: [:0]const u8) !Image {
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;

        const pixels = c.stbi_load(path, &width, &height, &channels, 0);

        if (pixels == null) {
            std.debug.print("Failed to load image: {s}\n", .{c.stbi_failure_reason()});
            return error.ReadFailure;
        }

        return .{
            .buf = pixels[0..@intCast(width * height * channels)],
            .width = @intCast(width),
            .height = @intCast(height),
            .channels = @intCast(channels),
            .is_stbi_src = true,
        };
    }

    fn fromRgb(arena: std.mem.Allocator, src: *Image) !Image {
        const out_buffer = try arena.alloc(u8, src.width * src.height);
        for (out_buffer) |*p| p.* = 0;

        var img: Image = .{
            .buf = out_buffer,
            .width = src.width,
            .height = src.height,
            .channels = 1,
        };

        for (0..src.height) |y| {
            for (0..src.width) |x| {
                const r = @as(u16, src.getWithOffset(y, x, 0));
                const g = @as(u16, src.getWithOffset(y, x, 1));
                const b = @as(u16, src.getWithOffset(y, x, 2));
                const val: u8 = @intCast((FACTOR_RED * r + FACTOR_GREEN * g + FACTOR_BLUE * b) >> 8);
                img.set(y, x, val);
            }
        }

        return img;
    }

    fn applyKernel(self: *Image, arena: std.mem.Allocator, kernel: []const []const i8) !Image {
        var new_img = try Image.fromImg(arena, self);
        const offset: i64 = @as(i64, @intCast(kernel.len - 1)) >> 1;

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                var sum: i64 = 0;
                var weight_sum: i64 = 0;
                for (kernel, 0..) |row, k_y| {
                    for (row, 0..) |factor, k_x| {
                        const offset_y: i64 = @as(i64, @intCast(k_y)) - offset;
                        const offset_x: i64 = @as(i64, @intCast(k_x)) - offset;
                        const img_y: i64 = @as(i64, @intCast(y)) + offset_y;
                        const img_x: i64 = @as(i64, @intCast(x)) + offset_x;

                        if (img_y < 0 or img_y >= self.height or img_x < 0 or img_x >= self.width) {
                            continue;
                        }

                        weight_sum += factor;
                        sum += @as(i16, @intCast(self.get(@intCast(img_y), @intCast(img_x)))) * @as(i16, @intCast(factor));
                    }
                }

                new_img.set(
                    y,
                    x,
                    @intFromFloat(
                        @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(weight_sum)),
                    ),
                );
            }
        }

        return new_img;
    }

    inline fn getIndex(self: *Image, y: usize, x: usize) usize {
        return (y * self.width + x) * self.channels;
    }

    inline fn get(self: *Image, y: usize, x: usize) u8 {
        return self.buf[self.getIndex(y, x)];
    }

    inline fn getWithOffset(self: *Image, y: usize, x: usize, offset: usize) u8 {
        return self.buf[self.getIndex(y, x) + offset];
    }

    inline fn set(self: *Image, y: usize, x: usize, val: u8) void {
        const index = self.getIndex(y, x);
        self.buf[index] = val;
    }

    fn write(self: *Image, path: [*c]const u8) !void {
        const result = c.stbi_write_jpg(
            path,
            @intCast(self.width),
            @intCast(self.height),
            @intCast(self.channels),
            self.buf.ptr,
            90,
        );

        if (result == 0) {
            return error.WriteFailure;
        }
    }
};

const GlyphMap = std.AutoHashMapUnmanaged(u8, Glyph);

const Glyph = struct {
    data: []u8,
    width: usize,
    height: usize,
};

fn createGlyphMap(io: std.Io, arena: std.mem.Allocator) !GlyphMap {
    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "fonts/Roboto-Regular.ttf", arena, .limited(2 * 1024 * 1024));

    var font: c.stbtt_fontinfo = undefined;
    if (c.stbtt_InitFont(&font, font_bytes.ptr, 0) == 0) {
        std.debug.print("Failed to init font\n", .{});
        return error.FontInitFailed;
    }

    const scale: f32 = c.stbtt_ScaleForPixelHeight(&font, 12);

    var map: GlyphMap = .{};

    for (characters) |char| {
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = chunk_size;
        var y1: c_int = chunk_size;

        c.stbtt_GetCodepointBitmapBox(&font, char, scale, scale, &x0, &y0, &x1, &y1);

        const glyph_w: usize = @intCast(x1 - x0);
        const glyph_h: usize = @intCast(y1 - y0);

        const glyph = try arena.alloc(u8, glyph_w * glyph_h);

        c.stbtt_MakeCodepointBitmap(
            &font,
            glyph.ptr,
            @as(c_int, @intCast(glyph_w)),
            @as(c_int, @intCast(glyph_h)),
            @as(c_int, @intCast(glyph_w)),
            scale,
            scale,
            char,
        );

        try map.put(arena, char, Glyph{ .data = glyph, .width = glyph_w, .height = glyph_h });
    }

    return map;
}
