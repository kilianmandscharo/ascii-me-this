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

const SOBEL_VERTICAL = &.{
    &.{ -1, 0, 1 },
    &.{ -2, 0, 2 },
    &.{ -1, 0, 1 },
};

const SOBEL_HORIZONTAL = &.{
    &.{ -1, -2, -1 },
    &.{ 0, 0, 0 },
    &.{ 1, 2, 1 },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    std.debug.print("{s}\n", .{args[0]});

    if (args.len < 2) {
        std.debug.print("usage: {s} <input_path>\n", .{args[0]});
        std.process.exit(1);
    }

    const input_path = args[1];

    var input_image = try Image.fromPath(input_path);
    defer input_image.deinit();

    var image = try Image.fromRgb(arena, &input_image);
    try image.write("./image_grayscale.jpg");

    image.gaussian();
    try image.write("./image_blurred.jpg");

    var directions = try image.sobel(arena);
    try image.write("./image_sobel.jpg");

    image.gradientMagnitudeThreshold(&directions);
    try image.write("./image_gradient_threshold.jpg");

    var doubleThreshold = try image.doubleThreshold(arena);
    try image.write("./image_double_threshold.jpg");

    try image.hysteresis(arena, &doubleThreshold.weak, &doubleThreshold.strong);
    try image.write("./image_hysteresis.jpg");

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

fn Grid(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T,
        width: usize,
        height: usize,
        channels: usize,

        fn fromGrid(arena: std.mem.Allocator, grid: *Self) !Self {
            const out_buffer = try arena.alloc(T, grid.width * grid.height);

            return .{
                .buf = out_buffer,
                .width = grid.width,
                .height = grid.height,
                .channels = grid.channels,
            };
        }

        fn init(arena: std.mem.Allocator, width: usize, height: usize, channels: usize) !Self {
            const out_buffer = try arena.alloc(T, width * height);

            return .{
                .buf = out_buffer,
                .width = width,
                .height = height,
                .channels = channels,
            };
        }

        fn initWithData(data: []T, width: usize, height: usize, channels: usize) Self {
            return .{
                .buf = data,
                .width = width,
                .height = height,
                .channels = channels,
            };
        }

        inline fn getIndex(self: *Self, y: usize, x: usize) usize {
            return (y * self.width + x) * self.channels;
        }

        pub inline fn get(self: *Self, y: usize, x: usize) T {
            return self.buf[self.getIndex(y, x)];
        }

        pub inline fn getWithOffset(self: *Self, y: usize, x: usize, offset: usize) T {
            return self.buf[self.getIndex(y, x) + offset];
        }

        pub inline fn set(self: *Self, y: usize, x: usize, val: T) void {
            const index = self.getIndex(y, x);
            self.buf[index] = val;
        }
    };
}

const Image = struct {
    grid: Grid(u8),
    is_stbi_src: bool = false,

    const Point = struct { x: usize, y: usize };
    const PointMap = std.AutoHashMapUnmanaged(Point, bool);

    const FACTOR_RED: u16 = 77;
    const FACTOR_GREEN: u16 = 150;
    const FACTOR_BLUE: u16 = 29;

    fn deinit(self: *Image) void {
        if (self.is_stbi_src) {
            c.stbi_image_free(self.grid.buf.ptr);
        }
    }

    fn fromImg(arena: std.mem.Allocator, src: *Image) !Image {
        return .{
            .grid = try Grid(u8).init(arena, src.grid.width, src.grid.height, src.grid.channels),
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
            .grid = Grid(u8).initWithData(
                pixels[0..@intCast(width * height * channels)],
                @intCast(width),
                @intCast(height),
                @intCast(channels),
            ),
            .is_stbi_src = true,
        };
    }

    fn fromRgb(arena: std.mem.Allocator, src: *Image) !Image {
        var img: Image = .{
            .grid = try Grid(u8).init(arena, src.grid.width, src.grid.height, 1),
        };

        for (0..src.grid.height) |y| {
            for (0..src.grid.width) |x| {
                const r = @as(u16, src.grid.getWithOffset(y, x, 0));
                const g = @as(u16, src.grid.getWithOffset(y, x, 1));
                const b = @as(u16, src.grid.getWithOffset(y, x, 2));
                const val: u8 = @intCast((FACTOR_RED * r + FACTOR_GREEN * g + FACTOR_BLUE * b) >> 8);
                img.grid.set(y, x, val);
            }
        }

        return img;
    }

    fn getNeighborsInDirection(self: *Image, y: usize, x: usize, angleInRad: f32) [2]?u8 {
        const angleInDeg = std.math.radiansToDegrees(angleInRad);
        const a = @mod(angleInDeg, 360);
        const zone: u8 = @intFromFloat(@divFloor(a, 22.5));

        var values: [2]?u8 = .{ null, null };

        const isVertical = zone == 15 or zone == 0 or zone == 7 or zone == 8;
        if (isVertical) {
            if (x > 0) values[0] = self.grid.get(y, x - 1);
            if (x + 1 < self.grid.width) values[1] = self.grid.get(y, x + 1);
            return values;
        }

        const isHorizontal = zone == 3 or zone == 4 or zone == 11 or zone == 12;
        if (isHorizontal) {
            if (y > 0) values[0] = self.grid.get(y - 1, x);
            if (y + 1 < self.grid.height) values[1] = self.grid.get(y + 1, x);
            return values;
        }

        const isDiagonalUp = zone == 1 or zone == 2 or zone == 9 or zone == 10;
        if (isDiagonalUp) {
            if (x > 0 and y + 1 < self.grid.height) values[0] = self.grid.get(y + 1, x - 1);
            if (x + 1 < self.grid.width and y > 0) values[1] = self.grid.get(y - 1, x + 1);
            return values;
        }

        const isDiagonalDown = zone == 5 or zone == 6 or zone == 13 or zone == 14;
        if (isDiagonalDown) {
            if (x + 1 < self.grid.width and y + 1 < self.grid.height) values[0] = self.grid.get(y + 1, x + 1);
            if (x > 0 and y > 0) values[1] = self.grid.get(y - 1, x - 1);
            return values;
        }

        unreachable;
    }

    fn gradientMagnitudeThreshold(self: *Image, directions: *Grid(f32)) void {
        for (0..self.grid.height) |y| {
            for (0..self.grid.width) |x| {
                const neighbors = self.getNeighborsInDirection(y, x, directions.get(y, x));
                const gradient = self.grid.get(y, x);

                var is_largest = true;

                if (neighbors[0] == null or neighbors[1] == null) {
                    is_largest = false;
                } else if (neighbors[0] != null and neighbors[0].? > gradient) {
                    is_largest = false;
                } else if (neighbors[1].? > gradient) {
                    is_largest = false;
                }

                if (is_largest) {
                    self.grid.set(y, x, gradient);
                } else {
                    self.grid.set(y, x, 0);
                }
            }
        }
    }

    fn doubleThreshold(self: *Image, arena: std.mem.Allocator) !struct { weak: PointMap, strong: PointMap } {
        const upper = 100;
        const lower = 40;

        var weak: std.AutoHashMapUnmanaged(Point, bool) = .empty;
        var strong: std.AutoHashMapUnmanaged(Point, bool) = .empty;

        for (0..self.grid.height) |y| {
            for (0..self.grid.width) |x| {
                const val = self.grid.get(y, x);
                if (val >= upper) {
                    try strong.put(arena, .{ .x = x, .y = y }, true);
                    self.grid.set(y, x, self.grid.get(y, x));
                } else if (val >= lower) {
                    try weak.put(arena, .{ .x = x, .y = y }, true);
                    self.grid.set(y, x, self.grid.get(y, x));
                } else {
                    self.grid.set(y, x, 0);
                }
            }
        }

        return .{
            .weak = weak,
            .strong = strong,
        };
    }

    fn hysteresis(self: *Image, arena: std.mem.Allocator, weak: *PointMap, strong: *PointMap) !void {
        var stack: std.ArrayList(Point) = .empty;
        var visited: PointMap = .empty;

        var it = strong.keyIterator();
        while (it.next()) |p| {
            try stack.append(arena, p.*);
        }

        while (stack.pop()) |p| {
            for (0..3) |y| {
                for (0..3) |x| {
                    const y_offset = @as(i64, @intCast(y)) - 1;
                    const x_offset = @as(i64, @intCast(x)) - 1;

                    if ((y_offset == 0 and x_offset == 0) or
                        (x_offset < 0 and p.x == 0 or x_offset > 0 and @as(i64, @intCast(p.x)) + x_offset >= self.grid.width) or
                        (y_offset < 0 and p.y == 0 or y_offset > 0 and @as(i64, @intCast(p.y)) + y_offset >= self.grid.height))
                    {
                        continue;
                    }

                    const new_x = @as(i64, @intCast(p.x)) + x_offset;
                    const new_y = @as(i64, @intCast(p.y)) + y_offset;
                    const neighbor: Point = .{ .x = @as(usize, @intCast(new_x)), .y = @as(usize, @intCast(new_y)) };

                    if (visited.contains(neighbor)) continue;
                    try visited.put(arena, neighbor, true);

                    if (weak.contains(neighbor)) {
                        try stack.append(arena, neighbor);
                        try strong.put(arena, neighbor, true);
                    }
                }
            }
        }

        for (0..self.grid.height) |y| {
            for (0..self.grid.width) |x| {
                if (!strong.contains(.{ .x = x, .y = y })) {
                    self.grid.set(y, x, 0);
                }
            }
        }
    }

    fn sobel(self: *Image, arena: std.mem.Allocator) !Grid(f32) {
        const kernel_ver: []const []const i8 = SOBEL_VERTICAL;
        const kernel_hor: []const []const i8 = SOBEL_HORIZONTAL;

        const kernel_height = kernel_ver.len;
        const kernel_width = kernel_ver[0].len;

        const offset: i64 = @as(i64, @intCast(kernel_height - 1)) >> 1;

        var new_grid = try Grid(u8).fromGrid(arena, &self.grid);
        var directions = try Grid(f32).init(arena, self.grid.width, self.grid.height, 1);

        for (0..self.grid.height) |y| {
            for (0..self.grid.width) |x| {
                var sum_ver: i64 = 0;
                var sum_hor: i64 = 0;

                for (0..kernel_height) |k_y| {
                    for (0..kernel_width) |k_x| {
                        const offset_y: i64 = @as(i64, @intCast(k_y)) - offset;
                        const offset_x: i64 = @as(i64, @intCast(k_x)) - offset;
                        const img_y: i64 = @as(i64, @intCast(y)) + offset_y;
                        const img_x: i64 = @as(i64, @intCast(x)) + offset_x;

                        if (img_y < 0 or img_y >= self.grid.height or img_x < 0 or img_x >= self.grid.width) {
                            continue;
                        }

                        const img_val: i16 = @intCast(self.grid.get(@intCast(img_y), @intCast(img_x)));
                        sum_ver += img_val * @as(i16, @intCast(kernel_ver[k_y][k_x]));
                        sum_hor += img_val * @as(i16, @intCast(kernel_hor[k_y][k_x]));
                    }
                }

                const val = @sqrt(@as(f32, @floatFromInt(sum_ver * sum_ver + sum_hor * sum_hor)));
                const dir = std.math.atan2(@as(f32, @floatFromInt(sum_ver)), @as(f32, @floatFromInt(sum_hor)));

                new_grid.set(y, x, @intFromFloat(val));
                directions.set(y, x, dir);
            }
        }

        self.grid = new_grid;

        return directions;
    }

    fn gaussian(self: *Image) void {
        const kernel: []const []const i8 = GAUSSIAN;
        const offset: i64 = @as(i64, @intCast(kernel.len - 1)) >> 1;

        for (0..self.grid.height) |y| {
            for (0..self.grid.width) |x| {
                var sum: i64 = 0;
                var weight_sum: i64 = 0;

                for (kernel, 0..) |row, k_y| {
                    for (row, 0..) |factor, k_x| {
                        const offset_y: i64 = @as(i64, @intCast(k_y)) - offset;
                        const offset_x: i64 = @as(i64, @intCast(k_x)) - offset;
                        const img_y: i64 = @as(i64, @intCast(y)) + offset_y;
                        const img_x: i64 = @as(i64, @intCast(x)) + offset_x;

                        if (img_y < 0 or img_y >= self.grid.height or img_x < 0 or img_x >= self.grid.width) {
                            continue;
                        }

                        weight_sum += factor;
                        sum += @as(i16, @intCast(self.grid.get(@intCast(img_y), @intCast(img_x)))) * @as(i16, @intCast(factor));
                    }
                }

                self.grid.set(
                    y,
                    x,
                    @intFromFloat(
                        @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(weight_sum)),
                    ),
                );
            }
        }
    }

    fn write(self: *Image, path: [*c]const u8) !void {
        const result = c.stbi_write_jpg(
            path,
            @intCast(self.grid.width),
            @intCast(self.grid.height),
            @intCast(self.grid.channels),
            self.grid.buf.ptr,
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
