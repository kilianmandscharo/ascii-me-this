const std = @import("std");
const c = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_image_write.h");
    @cInclude("stb_truetype.h");
});

const chunk_size = 10;
const characters = [_]u8{ '.', ':', 'c', 'o', 'P', 'O', '@', '$' };

pub fn main() !void {
    var width_from_image: c_int = 0;
    var height_from_image: c_int = 0;
    var channels_from_image: c_int = 0;

    const filename = "malenia.jpg";

    const pixels = c.stbi_load(filename, &width_from_image, &height_from_image, &channels_from_image, 0);
    if (pixels == null) {
        std.debug.print("Failed to load image: {s}\n", .{c.stbi_failure_reason()});
        return;
    }
    defer c.stbi_image_free(pixels);

    const width: usize = @intCast(width_from_image);
    const height: usize = @intCast(height_from_image);
    const channels: usize = @intCast(channels_from_image);

    std.debug.print("Loaded image {s}: {d}x{d}, channels={d}\n", .{ filename, width, height, channels });

    const number_of_rows: usize = @intCast(@divTrunc((width + chunk_size - 1), chunk_size));
    const number_of_cols: usize = @intCast(@divTrunc((height + chunk_size - 1), chunk_size));

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var out_buffer = try allocator.alloc(u8, width * height);
    defer allocator.free(out_buffer);

    for (out_buffer) |*p| p.* = 0;

    const font_bytes = try std.fs.cwd().readFileAlloc(allocator, "fonts/Roboto-Regular.ttf", 2 * 1024 * 1024);
    defer allocator.free(font_bytes);

    var font: c.stbtt_fontinfo = undefined;
    if (c.stbtt_InitFont(&font, font_bytes.ptr, 0) == 0) {
        std.debug.print("Failed to init font\n", .{});
        return;
    }

    const scale: f32 = c.stbtt_ScaleForPixelHeight(&font, 12);

    for (0..number_of_cols) |col_chunk| {
        for (0..number_of_rows) |row_chunk| {
            var total: f32 = 0;
            var count: usize = 0;

            for (0..chunk_size) |i| {
                for (0..chunk_size) |j| {
                    const y = col_chunk * chunk_size + i;
                    const x = row_chunk * chunk_size + j;

                    if (y >= height or x >= width) {
                        continue;
                    }

                    const offset = (y * width + x) * channels;
                    const r: f32 = @floatFromInt(pixels[offset]);
                    const g: f32 = @floatFromInt(pixels[offset + 1]);
                    const b: f32 = @floatFromInt(pixels[offset + 2]);
                    total += r * 0.299;
                    total += g * 0.587;
                    total += b * 0.114;
                    count += 1;
                }
            }

            const gray_scale_value: f32 = total / @as(f32, @floatFromInt(count));
            const char_index: usize = @intFromFloat(gray_scale_value / 256.0 * characters.len);

            const char: c_int = characters[char_index];

            var x0: c_int = @intCast(row_chunk * chunk_size);
            var y0: c_int = @intCast(col_chunk * chunk_size);
            var x1: c_int = @intCast(row_chunk * chunk_size + chunk_size);
            var y1: c_int = @intCast(col_chunk * chunk_size + chunk_size);

            c.stbtt_GetCodepointBitmapBox(&font, char, scale, scale, &x0, &y0, &x1, &y1);

            const glyph_w: usize = @intCast(x1 - x0);
            const glyph_h: usize = @intCast(y1 - y0);

            const glyph = try allocator.alloc(u8, glyph_w * glyph_h);

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

            for (0..glyph_h) |y| {
                for (0..glyph_w) |x| {
                    const src_offset = y * glyph_w + x;
                    const dst_x = x + row_chunk * chunk_size;
                    const dst_y = y + col_chunk * chunk_size;
                    if (dst_x < width and dst_y < height) {
                        out_buffer[dst_y * width + dst_x] = glyph[src_offset];
                    }
                }
            }

            allocator.free(glyph);
        }
    }

    const result = c.stbi_write_jpg(
        "malenia_out.jpg",
        width_from_image,
        height_from_image,
        1,
        out_buffer.ptr,
        90,
    );

    if (result == 0) {
        std.debug.print("Failed to write image\n", .{});
    } else {
        std.debug.print("Image written successfully\n", .{});
    }
}
