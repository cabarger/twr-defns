const std = @import("std");
const rl = @import("raylib");

const max_layers = 5;
const max_unique_track_tiles = 5;
const scale_factor = 3;
const map_width_in_tiles = 16;
const map_height_in_tiles = 16;
const sprite_width = 32;
const sprite_height = 32;
const map_width = sprite_width * map_width_in_tiles * scale_factor;
const map_height = @floatToInt(c_int, isoTransform(@intToFloat(f32, map_width_in_tiles), @intToFloat(f32, map_height_in_tiles)).y) + sprite_height * scale_factor / 2;

// TODO(caleb):

// 2) ACTUALLY fix offsets for towers and enemies??? I could just offset by half sprite height ( that seems ok for now )
// 4) Fix sprite render order.

const anim_frames_speed = 10;
const enemy_tps = 2; // Enemy tiles per second

const Tileset = struct {
    columns: u32,
    track_start_id: u32,
    tile_id_count: u8,
    track_tile_ids: [max_unique_track_tiles]u32, // This is silly..
    tex: rl.Texture,

    pub fn checkIsTrackTile(self: Tileset, target_tile_id: u32) bool {
        var track_tile_index: u8 = 0;
        while (track_tile_index < self.tile_id_count) : (track_tile_index += 1) {
            if (self.track_tile_ids[track_tile_index] == target_tile_id) {
                return true;
            }
        }
        return false;
    }
};

const Map = struct {
    tile_indicies: std.ArrayList(u32),
    first_gid: u32,

    pub fn tileIndexFromCoord(self: *Map, tile_x: u32, tile_y: u32) ?u32 {
        std.debug.assert(tile_y * map_width_in_tiles + tile_x < self.*.tile_indicies.items.len);
        const map_tile_index = self.*.tile_indicies.items[tile_y * map_width_in_tiles + tile_x];
        return if (@intCast(i32, map_tile_index) - @intCast(i32, self.*.first_gid) < 0) null else
            @intCast(u32, @intCast(i32, map_tile_index) - @intCast(i32, self.*.first_gid));
    }
};

const Direction = enum(u32) {
    left = 0,
    up,
    down,
    right,
};

const Enemy = struct {
    direction: Direction,
    pos: rl.Vector2,
    prev_pos: rl.Vector2,
};

const Tower = struct {
    direction: Direction,
    tile_x: u32,
    tile_y: u32,
    anim_index: u32,
    range: u32,
};

inline fn boundsCheck(x: i32, y: i32, dx: i32, dy: i32) bool {
    if ((y + dy < 0) or (y + dy >= map_height_in_tiles) or
        (x + dx < 0) or (x + dx >= map_width_in_tiles))
    {
        return false;
    }
    return true;
}

inline fn movingBackwards(x: f32, y: f32, prev_x: f32, prev_y: f32) bool {
    return ((x == prev_x) and y == prev_y);
}

fn updateEnemy(tileset: *Tileset, map: *Map, enemy: *Enemy) void {
    var move_amt = rl.Vector2{ .x = 0, .y = 0 };
    switch (enemy.*.direction) {
        .left => move_amt.x -= 1,
        .up => move_amt.y -= 1,
        .down => move_amt.y += 1,
        .right => move_amt.x += 1,
    }

    const tile_x = @floatToInt(i32, @round(enemy.*.pos.x));
    const tile_y = @floatToInt(i32, @round(enemy.*.pos.y));
    const tile_dx = @floatToInt(i32, @round(move_amt.x));
    const tile_dy = @floatToInt(i32, @round(move_amt.y));

    if (!boundsCheck(tile_x, tile_y, tile_dx, tile_dy)) {
        return;
    }

    const target_tile_id = map.tile_indicies.items[@intCast(u32, tile_y + tile_dy) * map_width_in_tiles + @intCast(u32, tile_x + tile_dx)] - 1;
    if (tileset.checkIsTrackTile(target_tile_id) and !movingBackwards(enemy.*.pos.x + move_amt.x, enemy.pos.y + move_amt.y, enemy.*.prev_pos.x, enemy.*.prev_pos.y)) {
        enemy.*.prev_pos = enemy.*.pos;
        enemy.*.pos.x += move_amt.x;
        enemy.*.pos.y += move_amt.y;
    } else { // Choose new direction
        enemy.*.direction = @intToEnum(Direction, @mod(@enumToInt(enemy.*.direction) + 1, @enumToInt(Direction.right) + 1));
        updateEnemy(tileset, map, enemy);
    }
}

const i_isometric_trans = rl.Vector2{ .x = @intToFloat(f32, sprite_width * scale_factor) * 0.5, .y = @intToFloat(f32, sprite_height * scale_factor) * 0.25 };
const j_isometric_trans = rl.Vector2{ .x = -1 * @intToFloat(f32, sprite_width * scale_factor) * 0.5, .y = @intToFloat(f32, sprite_height * scale_factor) * 0.25 };

fn isoTransform(x: f32, y: f32) rl.Vector2 {
    const input = rl.Vector2{ .x = x, .y = y };
    var out = rl.Vector2{
        .x = input.x * i_isometric_trans.x + input.y * j_isometric_trans.x,
        .y = input.x * i_isometric_trans.y + input.y * j_isometric_trans.y,
    };
    return out;
}

fn isoTransformWithScreenOffset(x: f32, y: f32) rl.Vector2 {
    var out = isoTransform(x, y);

    const screen_offset = rl.Vector2{
        .x = @intToFloat(f32, rl.GetScreenWidth()) / 2 - sprite_width * scale_factor / 2,
        .y = (@intToFloat(f32, rl.GetScreenHeight()) - @intToFloat(f32, map_height)) / 2
    };

    out.x += screen_offset.x;
    out.y += screen_offset.y;

    return out;
}

fn isoInvert(x: f32, y: f32) rl.Vector2 {
    const screen_offset = rl.Vector2{
        .x = @intToFloat(f32, rl.GetScreenWidth()) / 2 - sprite_width * scale_factor / 2,
        .y = (@intToFloat(f32, rl.GetScreenHeight()) - @intToFloat(f32, map_height)) / 2
    };

    const input = rl.Vector2{
        .x = x - screen_offset.x,
        .y = y - screen_offset.y
    };

    const det = 1 / (i_isometric_trans.x * j_isometric_trans.y - j_isometric_trans.x * i_isometric_trans.y);
    const i_invert_isometric_trans = rl.Vector2{ .x = j_isometric_trans.y * det, .y = i_isometric_trans.y * det * -1 };
    const j_invert_isometric_trans = rl.Vector2{ .x = j_isometric_trans.x * det * -1, .y = i_isometric_trans.x * det };

    return rl.Vector2{
        .x = input.x * i_invert_isometric_trans.x + input.y * j_invert_isometric_trans.x,
        .y = input.x * i_invert_isometric_trans.y + input.y * j_invert_isometric_trans.y,
    };
}


pub fn main() !void {
    rl.InitWindow(map_width, map_height, "twr-defns");
    rl.SetWindowState(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE);
    rl.SetWindowState(rl.ConfigFlags.FLAG_VSYNC_HINT);
    rl.SetWindowMinSize(map_width, map_height);
    rl.SetTargetFPS(60);

    rl.InitAudioDevice();
    defer rl.CloseAudioDevice();
    rl.SetMasterVolume(1);
    //    bool IsAudioDeviceReady(void);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var ally = arena.allocator();
    var parser = std.json.Parser.init(ally, false);
    defer parser.deinit();

    // Load tileset
    var tileset: Tileset = undefined;
    tileset.tex = rl.LoadTexture("assets/calebsprites/isosheet.png");
    defer rl.UnloadTexture(tileset.tex);
    {
        const tileset_file = try std.fs.cwd().openFile("assets/calebsprites/isosheet.tsj", .{});
        defer tileset_file.close();
        var raw_tileset_json = try tileset_file.reader().readAllAlloc(ally, 1024 * 5); // 5kib should be enough
        defer ally.free(raw_tileset_json);

        var parsed_tileset_data = try parser.parse(raw_tileset_json);

        const columns_value = parsed_tileset_data.root.Object.get("columns") orelse unreachable;
        tileset.columns = @intCast(u32, columns_value.Integer);

        const tile_data = parsed_tileset_data.root.Object.get("tiles") orelse unreachable;
        tileset.tile_id_count = @intCast(u8, tile_data.Array.items.len);
        for (tile_data.Array.items) |tile, tile_index| {
            const tile_id = tile.Object.get("id") orelse unreachable;
            const tile_type = tile.Object.get("type") orelse unreachable;

            if (std.mem.eql(u8, tile_type.String, "track")) {
                tileset.track_tile_ids[tile_index] = @intCast(u32, tile_id.Integer);
            } else if (std.mem.eql(u8, tile_type.String, "track_start")) {
                tileset.track_tile_ids[tile_index] = @intCast(u32, tile_id.Integer);
                tileset.track_start_id = @intCast(u32, tile_id.Integer);
            } else {
                unreachable;
            }
        }
    }

    var board_map: Map = undefined;
    board_map.tile_indicies = std.ArrayList(u32).init(ally);
    defer board_map.tile_indicies.deinit();
    {
        const map_file = try std.fs.cwd().openFile("assets/calebsprites/map1.tmj", .{});
        defer map_file.close();
        var map_json = try map_file.reader().readAllAlloc(ally, 1024 * 10);
        defer ally.free(map_json);

        parser.reset();
        var parsed_map = try parser.parse(map_json);
        const layers = parsed_map.root.Object.get("layers") orelse unreachable;
        std.debug.assert(layers.Array.items.len == 1);
        const layer = layers.Array.items[0];
        const tile_data = layer.Object.get("data") orelse unreachable;
        for (tile_data.Array.items) |tile_index| {
            try board_map.tile_indicies.append(@intCast(u32, tile_index.Integer));
        }

        var tilesets = parsed_map.root.Object.get("tilesets") orelse unreachable;
        std.debug.assert(tilesets.Array.items.len == 1);
        const first_gid = tilesets.Array.items[0].Object.get("firstgid") orelse unreachable;
        board_map.first_gid = @intCast(u32, first_gid.Integer);
    }

    // Store FIRST animation index for each sprite in tile set.
    // NOTE(caleb): There are 4 animations stored per index in this list. ( up-left, up-right, down-left, down-right)
    //  where each animation is 4 frames in length.
    var anim_map: Map = undefined;
    anim_map.tile_indicies = std.ArrayList(u32).init(ally);
    defer anim_map.tile_indicies.deinit();
    {
        const anim_file = try std.fs.cwd().openFile("assets/calebsprites/anims.tmj", .{});
        defer anim_file.close();
        var raw_anim_json = try anim_file.reader().readAllAlloc(ally, 1024 * 5); // 5kib should be enough
        defer ally.free(raw_anim_json);

        parser.reset();
        var parsed_anim = try parser.parse(raw_anim_json);
        var layers = parsed_anim.root.Object.get("layers") orelse unreachable;
        std.debug.assert(layers.Array.items.len == 1);
        const layer = layers.Array.items[0];
        var anim_data = layer.Object.get("data") orelse unreachable;
        for (anim_data.Array.items) |tile_index| {
            try anim_map.tile_indicies.append(@intCast(u32, tile_index.Integer));
        }

        var tilesets = parsed_anim.root.Object.get("tilesets") orelse unreachable;
        std.debug.assert(tilesets.Array.items.len == 1);
        const first_gid = tilesets.Array.items[0].Object.get("firstgid") orelse unreachable;
        anim_map.first_gid = @intCast(u32, first_gid.Integer);
    }

    const jam = rl.LoadSound("assets/bigjjam.wav");
    defer rl.UnloadSound(jam);

    var anim_current_frame: u8 = 0;
    var anim_frames_counter: u8 = 0;
    var enemy_tps_frame_counter: u8 = 0;

    var enemy_start_tile_y: u32 = 0;
    var enemy_start_tile_x: u32 = 0;
    {
        var found_enemy_start_tile = false;
        outer: while (enemy_start_tile_y < map_height_in_tiles) : (enemy_start_tile_y += 1) {
            enemy_start_tile_x = 0;
            while (enemy_start_tile_x < map_width_in_tiles) : (enemy_start_tile_x += 1) {
                const map_tile_index = board_map.tileIndexFromCoord(enemy_start_tile_x, enemy_start_tile_y) orelse continue;
                if ((map_tile_index) == tileset.track_start_id) {
                    found_enemy_start_tile = true;
                    break :outer;
                }
            }
        }
        std.debug.assert(found_enemy_start_tile);
    }

    var towers = std.ArrayList(Tower).init(ally);
    defer towers.deinit();

    var alive_enemies = std.ArrayList(Enemy).init(ally);
    defer alive_enemies.deinit();

    // TODO(caleb): Disable escape key to close... ( why is this on by default? )
    while (!rl.WindowShouldClose()) { // Detect window close button or ESC key
        if (!rl.IsSoundPlaying(jam)) { // and rl.IsMusicReady(jam)) {
            rl.PlaySound(jam);
        }

        anim_frames_counter += 1;
        if (anim_frames_counter >= @divTrunc(60, anim_frames_speed)) {
            anim_frames_counter = 0;
            anim_current_frame += 1;
            if (anim_current_frame > 3) anim_current_frame = 0; // NOTE(caleb): 3 is frames per animation - 1
        }

        enemy_tps_frame_counter += 1;
        if (enemy_tps_frame_counter >= @divTrunc(60, enemy_tps)) {
            enemy_tps_frame_counter = 0;

            // Update enemies

            for (alive_enemies.items) |*enemy| {
                updateEnemy(&tileset, &board_map, enemy);
            }

            if (alive_enemies.items.len < 10) {
                const newEnemy = Enemy{
                    .direction = Direction.left,
                    .pos = rl.Vector2{ .x = @intToFloat(f32, enemy_start_tile_x), .y = @intToFloat(f32, enemy_start_tile_y) },
                    .prev_pos = rl.Vector2{ .x = @intToFloat(f32, enemy_start_tile_x), .y = @intToFloat(f32, enemy_start_tile_y) },
                };
                try alive_enemies.append(newEnemy);
            }
        }

        // Get mouse position
        var mouse_pos = rl.GetMousePosition();
        var selected_tile_pos = isoInvert(@round(mouse_pos.x), @round(mouse_pos.y));
        const selected_tile_x = @floatToInt(i32, selected_tile_pos.x);
        const selected_tile_y = @floatToInt(i32, selected_tile_pos.y);

        // Place tower on selected tile
        if (rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and selected_tile_x < map_width_in_tiles and selected_tile_y < map_height_in_tiles and selected_tile_x >= 0 and selected_tile_y >= 0) {
            var hasTower = false;
            for (towers.items) |tower| {
                if ((tower.tile_x == @intCast(u32, selected_tile_y)) and
                    (tower.tile_y == @intCast(u32, selected_tile_x)))
                {
                    hasTower = true;
                    break;
                }
            }
            if (!hasTower) {
                try towers.append(Tower{
                    .direction = Direction.down,
                    .tile_x = @intCast(u32, selected_tile_x),
                    .tile_y = @intCast(u32, selected_tile_y),
                    .anim_index = anim_map.tile_indicies.items[1] - anim_map.first_gid, // TODO(caleb): decide tower type...
                    .range = 4,
                });
            }
        }

        // Tower lock on
        for (towers.items) |*tower| {
            const start_tile_x = @max(0, @intCast(i32, tower.tile_x) - @intCast(i32, @divTrunc(tower.range, 2)));
            const start_tile_y = @max(0, @intCast(i32, tower.tile_y) - @intCast(i32, @divTrunc(tower.range, 2)));

            var tile_y = start_tile_y;
            while (tile_y < start_tile_y + @intCast(i32, tower.range)) : (tile_y += 1) {
                var tile_x = start_tile_x;
                while(tile_x < start_tile_x + @intCast(i32, tower.range)) : (tile_x += 1) {
                    if ((tile_x > map_width_in_tiles) or (tile_y > map_height_in_tiles)) {
                        continue;
                    }

                    const tile_index = board_map.tile_indicies.items[@intCast(u32, tile_y * map_width_in_tiles + tile_x)];
                    if (tileset.checkIsTrackTile(tile_index)) {
                        for (alive_enemies.items) |enemy| {
                            const enemy_tile_x = @floatToInt(i32, @round(enemy.pos.x));
                            const enemy_tile_y = @floatToInt(i32, @round(enemy.pos.y));
                            if (tile_x == enemy_tile_x and tile_y == enemy_tile_y) {

                                // lock onto this enemy.
                                if (enemy_tile_y < tower.tile_y) {
                                    tower.direction = Direction.up;
                                }
                                else if (enemy_tile_y == tower.tile_y and enemy_tile_x > tower.tile_x) {
                                    tower.direction = Direction.right;
                                }
                                else if (enemy_tile_y > tower.tile_y) {
                                    tower.direction = Direction.down;
                                }
                                else if (enemy_tile_y == tower.tile_y and enemy_tile_x < tower.tile_x) {
                                    tower.direction = Direction.left;
                                }
                            }
                        }
                    }
                }
            }
        }

        rl.BeginDrawing();
        rl.ClearBackground(rl.Color{ .r = 77, .g = 128, .b = 201, .a = 255 });

        var tile_y: i32 = 0;
        while (tile_y < map_height_in_tiles) : (tile_y += 1) {
            var tile_x: i32 = 0;
            while (tile_x < map_width_in_tiles) : (tile_x += 1) {
                const map_tile_index = board_map.tileIndexFromCoord(@intCast(u32, tile_x), @intCast(u32, tile_y)) orelse continue;
                var dest_pos = isoTransformWithScreenOffset(@intToFloat(f32, tile_x), @intToFloat(f32, tile_y));
                if (tile_x == selected_tile_x and tile_y == selected_tile_y) {
                    dest_pos.y -= 10;
                }

                const dest_rect = rl.Rectangle{
                    .x = dest_pos.x,
                    .y = dest_pos.y,
                    .width = sprite_width * scale_factor,
                    .height = sprite_height * scale_factor,
                };

                const target_tile_row = @divTrunc(map_tile_index, tileset.columns);
                const target_tile_column = @mod(map_tile_index, tileset.columns);
                const source_rect = rl.Rectangle{
                    .x = @intToFloat(f32, target_tile_column * sprite_width),
                    .y = @intToFloat(f32, target_tile_row * sprite_height),
                    .width = sprite_width,
                    .height = sprite_height,
                };

                rl.DrawTexturePro(tileset.tex, source_rect, dest_rect, .{ .x = 0, .y = 0 }, 0, rl.WHITE);
            }
        }

        for (towers.items) |tower| {
            const anim_tile_index = tower.anim_index + @enumToInt(tower.direction) * 4 + anim_current_frame;

            var dest_pos = isoTransformWithScreenOffset(@intToFloat(f32, tower.tile_x), @intToFloat(f32, tower.tile_y));

            dest_pos.y -= sprite_height * scale_factor / 2;

            const dest_rect = rl.Rectangle{
                .x = dest_pos.x,
                .y = dest_pos.y,
                .width = sprite_width * scale_factor,
                .height = sprite_height * scale_factor,
            };

            const target_tile_row = @divTrunc(anim_tile_index, tileset.columns);
            const target_tile_column = @mod(anim_tile_index, tileset.columns);
            const source_rect = rl.Rectangle{
                .x = @intToFloat(f32, target_tile_column * sprite_width),
                .y = @intToFloat(f32, target_tile_row * sprite_height),
                .width = sprite_width,
                .height = sprite_height,
            };

            rl.DrawTexturePro(tileset.tex, source_rect, dest_rect, .{ .x = 0, .y = 0 }, 0, rl.WHITE);
        }

        // Draw enemies
        var enemy_index = @intCast(i32, alive_enemies.items.len) - 1;
        while (enemy_index >= 0) : (enemy_index -= 1) {
            const anim_tile_index = anim_map.tile_indicies.items[0] + @enumToInt(alive_enemies.items[@intCast(u32, enemy_index)].direction) * 4 + anim_current_frame;
            std.debug.assert(anim_tile_index != 0); // Has an anim?
            const target_tile_row = @divTrunc(anim_tile_index - anim_map.first_gid, tileset.columns);
            const target_tile_column = @mod(anim_tile_index - anim_map.first_gid, tileset.columns);

            var dest_pos = isoTransformWithScreenOffset(alive_enemies.items[@intCast(u32, enemy_index)].pos.x, alive_enemies.items[@intCast(u32, enemy_index)].pos.y);

            dest_pos.y -= sprite_height * scale_factor / 2;

            const dest_rect = rl.Rectangle{
                .x = dest_pos.x,
                .y = dest_pos.y,
                .width = sprite_width * scale_factor,
                .height = sprite_height * scale_factor,
            };
            const source_rect = rl.Rectangle{
                .x = @intToFloat(f32, target_tile_column * sprite_width),
                .y = @intToFloat(f32, target_tile_row * sprite_height),
                .width = sprite_width,
                .height = sprite_height,
            };

            rl.DrawTexturePro(tileset.tex, source_rect, dest_rect, .{ .x = 0, .y = 0 }, 0, rl.WHITE);
        }

        rl.EndDrawing();
    }

    rl.CloseWindow();
}
