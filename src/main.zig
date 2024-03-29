// TODO(caleb):
// ========================
// *More towers
// *More enemies
// *Tower upgrades
// *Modify tile id hashmap values to also track sprite offsets.
// *Rounds past 20 ( freeplay mode )

const std = @import("std");
const rl = @import("raylib");
const rlm = @import("raylib-math");

const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;

const hashString = std.hash_map.hashString;

const target_fps = 60;
const tower_buy_area_sprite_scale = 0.75;
const tower_buy_area_towers_per_row = 1;
const default_font_size = 20;
const font_spacing = 2;
const board_width_in_tiles = 16;
const board_height_in_tiles = 16;
const sprite_width = 32;
const sprite_height = 32;
const anim_frames_speed = 7;
const death_anim_frames_speed = 15;
const color_off_black = rl.Color{ .r = 34, .g = 35, .b = 35, .a = 255 };
const color_off_white = rl.Color{ .r = 240, .g = 246, .b = 240, .a = 255 };
const initial_scale_factor = 4;

var scale_factor: f32 = initial_scale_factor;
var board_translation = rl.Vector2{ .x = 0, .y = 0 };

const GameState = struct {
    money: i32,
    hp: i32,
    round: u32,
    selected_tower: ?*Tower,
    tower_index_being_placed: i32,
    round_in_progress: bool,
    round_gsd: [@enumToInt(EnemyKind.count)]GroupSpawnData,

    towers: ArrayList(Tower),
    alive_enemies: ArrayList(Enemy),
    dead_enemies: ArrayList(DeadEnemy),
    projectiles: ArrayList(Projectile),
    money_change: ArrayList(StatusChangeEntry),
    hp_change: ArrayList(StatusChangeEntry),

    pub fn reset(self: *GameState) void {
        self.money = 200;
        self.hp = 200;
        self.round = 0;
        self.selected_tower = null;
        self.tower_index_being_placed = -1;
        self.round_in_progress = false;
        for (self.round_gsd) |*gsd_entry| {
            gsd_entry.time_between_spawns_ms = 0;
            gsd_entry.spawn_count = 0;
        }

        self.towers.clearRetainingCapacity();
        self.alive_enemies.clearRetainingCapacity();
        self.dead_enemies.clearRetainingCapacity();
        self.projectiles.clearRetainingCapacity();
        self.money_change.clearRetainingCapacity();
        self.hp_change.clearRetainingCapacity();
    }
};

const Tileset = struct {
    columns: u16,
    tex: rl.Texture,
    tile_name_to_id: AutoHashMap(u64, u16),

    pub inline fn isTrackTile(self: Tileset, target_tile_id: u16) bool {
        var result = false;
        if ((self.tile_name_to_id.get(hashString("track_start")).? == target_tile_id) or
            (self.tile_name_to_id.get(hashString("track")).? == target_tile_id))
        {
            result = true;
        }
        return result;
    }
};

const Map = struct {
    tile_indicies: ArrayList(u16),
    first_gid: u16,

    pub fn tileIDFromCoord(self: *Map, tile_x: u16, tile_y: u16) ?u16 {
        std.debug.assert(tile_y * board_width_in_tiles + tile_x < self.*.tile_indicies.items.len);
        const ts_id = self.tile_indicies.items[tile_y * board_width_in_tiles + tile_x];
        return if (@intCast(i32, ts_id) - @intCast(i32, self.*.first_gid) < 0) null else @intCast(u16, @intCast(i32, ts_id) - @intCast(i32, self.*.first_gid));
    }
};

const GameMode = enum {
    title_screen,
    running,
    game_end,
};

const Direction = enum(u32) {
    left = 0,
    up,
    down,
    right,
};

const EnemyData = struct {
    hp: u32,
    move_speed: f32,
    tile_id: u32,
    tile_steps_per_second: u8,
};

const EnemyKind = enum(u32) {
    gremlin_wiz_guy = 0,
    slime,
    count,
};

const GroupSpawnData = struct {
    kind: EnemyKind,
    spawn_count: u32,
    time_between_spawns_ms: u16,
};

const RoundSpawns = struct {
    group_spawn_data: [@enumToInt(EnemyKind.count)]GroupSpawnData,
    unique_enemies_for_this_round: u8,
};

var enemies_data = [_]EnemyData{
    EnemyData{ // Gremlin wiz guy
        .hp = 3,
        .move_speed = 2.0,
        .tile_id = undefined,
        .tile_steps_per_second = 64,
    },
    EnemyData{ // Slime
        .hp = 1,
        .move_speed = 1.0,
        .tile_id = undefined,
        .tile_steps_per_second = 64,
    },
};

const DeadEnemy = struct {
    pos: rl.Vector2,
    anim_frame: u8,
    anim_timer: u8,
};

const Enemy = struct {
    kind: EnemyKind,
    direction: Direction,
    last_step_direction: Direction,
    hp: i32,
    pos: rl.Vector2,
    colliders: [2]rl.Rectangle,
    tile_steps_per_second: u8,
    tile_step_timer: u8,
    anim_frame: u8,
    anim_timer: u8,

    /// Updates collider positions rel to enemy pos.
    fn shiftColliders(self: *Enemy) void {
        var y_offset: f32 = sprite_height * scale_factor / 2;
        for (self.colliders) |*collider| {

            // TODO(caleb): Read sprite offsets from tileset lookup.
            const enemy_screen_space_pos = isoProject(self.pos.x, self.pos.y, 1);
            const collider_screen_space_pos = rl.Vector2{
                .x = enemy_screen_space_pos.x + (sprite_width * scale_factor - collider.width * scale_factor) / 2,
                .y = enemy_screen_space_pos.y + y_offset,
            };
            const collider_tile_space_pos = isoProjectInverted(collider_screen_space_pos.x, collider_screen_space_pos.y, 1);
            collider.x = collider_tile_space_pos.x;
            collider.y = collider_tile_space_pos.y;

            y_offset += collider.height * scale_factor;
        }
    }
    fn initColliders(self: *Enemy) void {
        // TODO(caleb): Get hitbox info from a tileset lookup.
        for (self.colliders) |*collider| {
            collider.width = 0;
            collider.height = 0;
        }
        switch (self.kind) {
            .gremlin_wiz_guy => {
                self.colliders[0].width = 12; // ~Head
                self.colliders[0].height = 8;

                self.colliders[1].width = 14; // ~Body
                self.colliders[1].height = 8;
            },
            .slime => {
                self.colliders[0].width = 16; // ~Body
                self.colliders[0].height = 15;
            },
            else => unreachable,
        }

        self.shiftColliders();
    }
};

const tower_names = [_][*c]const u8{
    "Floating eye",
    "The Bank",
};

const tower_descs = [_][*c]const u8{
    "Your average tower that shoots enemies...\nWITH MIND BULLETS!!",
    "It makes you money.",
};

const TowerKind = enum(u32) {
    floating_eye = 0,
    bank,
};

const TowerData = struct {
    damage: u32,
    tile_id: u32,
    range: u16,
    fire_rate: f32,
    fire_speed: f32,
    cost: u16,
};

var towers_data = [_]TowerData{
    TowerData{ // floating eye
        .damage = 1,
        .range = 6,
        .tile_id = undefined,
        .fire_rate = 1.0,
        .fire_speed = 10,
        .cost = 200,
    },
    TowerData{ // bank
        .damage = 20,
        .range = 1,
        .tile_id = undefined,
        .fire_rate = 0.2,
        .fire_speed = 10,
        .cost = 300,
    },
};

const Tower = struct {
    kind: TowerKind,
    direction: Direction,
    tile_x: u16,
    tile_y: u16,
    fire_rate: f32,
    fire_rate_timer: f32,
    fire_speed: f32,
    anim_frame: u8,
    anim_timer: u8,
};

const ProjectileKind = enum {
    bullet,
    coin,
};

const Projectile = struct {
    kind: ProjectileKind,
    direction: rl.Vector2,
    start: rl.Vector2,
    target: rl.Vector2,
    speed: f32,
    pos: rl.Vector2,
    damage: u32,
};

const DrawBufferEntry = struct {
    tile_pos: rl.Vector2,
    ts_id: u32,
};

const StatusChangeEntry = struct {
    d_value: i32,
    d_pos: rl.Vector2,
};

const Input = struct {
    l_mouse_button_is_down: bool,
    mouse_pos: rl.Vector2,
};

inline fn boundsCheck(x: i32, y: i32) bool {
    if ((y < 0) or (y >= board_height_in_tiles) or
        (x < 0) or (x >= board_width_in_tiles))
    {
        return false;
    }
    return true;
}

inline fn clampf32(value: f32, min: f32, max: f32) f32 {
    return @max(min, @min(max, value));
}

inline fn screenSpaceBoardHeight() c_int {
    const result = @floatToInt(c_int, isoProjectBase(@intToFloat(f32, board_width_in_tiles), @intToFloat(f32, board_height_in_tiles), 0).y) + @divTrunc(sprite_height * @floatToInt(c_int, scale_factor), 2);
    return result;
}

fn updateEnemy(tileset: *Tileset, map: *Map, enemy: *Enemy) void {
    var move_amt = rl.Vector2{ .x = 0, .y = 0 };
    switch (enemy.*.direction) {
        .left => move_amt.x -= 1 / @intToFloat(f32, enemy.tile_steps_per_second) * enemies_data[@enumToInt(enemy.kind)].move_speed,
        .up => move_amt.y -= 1 / @intToFloat(f32, enemy.tile_steps_per_second) * enemies_data[@enumToInt(enemy.kind)].move_speed,
        .down => move_amt.y += 1 / @intToFloat(f32, enemy.tile_steps_per_second) * enemies_data[@enumToInt(enemy.kind)].move_speed,
        .right => move_amt.x += 1 / @intToFloat(f32, enemy.tile_steps_per_second) * enemies_data[@enumToInt(enemy.kind)].move_speed,
    }
    const next_tile_pos = rlm.Vector2Add(enemy.pos, move_amt);
    const target_tile_id = map.tile_indicies.items[@floatToInt(u32, next_tile_pos.y) * board_width_in_tiles + @floatToInt(u32, next_tile_pos.x)] - 1;
    if (tileset.isTrackTile(target_tile_id)) {
        var is_valid_move = true;

        // If moving down check 1 tile down ( we want to keep a tile rel y pos of 0 before turning )
        if (enemy.direction == Direction.down) {

            // If not in bounds than don't worry about checking tile.
            if (boundsCheck(@floatToInt(i32, @floor(next_tile_pos.x)), @floatToInt(i32, @floor(next_tile_pos.y)) + 1)) {
                const plus1_y_target_tile_id = map.tile_indicies.items[(@floatToInt(u32, @floor(next_tile_pos.y)) + 1) * board_width_in_tiles + @floatToInt(u32, @floor(next_tile_pos.x))] - 1;

                // Invalidate move
                if (!tileset.isTrackTile(plus1_y_target_tile_id) and next_tile_pos.y - @floor(next_tile_pos.y) > 0) {
                    // Align enemy pos y
                    enemy.pos.y = @floor(next_tile_pos.y);
                    is_valid_move = false;
                }
            }
        } else if (enemy.direction == Direction.right) {

            // Again not in bounds, don't worry about checking tile.
            if (boundsCheck(@floatToInt(i32, @floor(next_tile_pos.x)) + 1, @floatToInt(i32, @floor(next_tile_pos.y)))) {
                const plus1_x_target_tile_id = map.tile_indicies.items[@floatToInt(u32, @floor(next_tile_pos.y)) * board_width_in_tiles + @floatToInt(u32, @floor(next_tile_pos.x)) + 1] - 1;

                // Invalidate move
                if (!tileset.isTrackTile(plus1_x_target_tile_id) and next_tile_pos.x - @floor(next_tile_pos.x) > 0) {
                    // Align enemy pos x
                    enemy.pos.x = @floor(next_tile_pos.x);
                    is_valid_move = false;
                }
            }
        }

        if (is_valid_move) {
            enemy.pos = next_tile_pos;
            enemy.last_step_direction = enemy.direction;
            enemy.shiftColliders();
            return;
        }
    }

    // Choose new direction
    const current_direction = enemy.direction;
    enemy.direction = @intToEnum(Direction, @mod(@enumToInt(enemy.*.direction) + 1, @enumToInt(Direction.right) + 1));
    while (enemy.direction != current_direction) : (enemy.direction = @intToEnum(Direction, @mod(@enumToInt(enemy.direction) + 1, @enumToInt(Direction.right) + 1))) {
        var future_target_tile_id: ?u16 = null;
        switch (enemy.direction) {
            .right => {
                if (boundsCheck(@floatToInt(i32, enemy.pos.x) + 1, @floatToInt(i32, enemy.pos.y)) and enemy.last_step_direction != Direction.left) {
                    future_target_tile_id = map.tile_indicies.items[@floatToInt(u32, enemy.pos.y) * board_width_in_tiles + @floatToInt(u32, enemy.pos.x) + 1] - 1;
                }
            },
            .left => {
                if (boundsCheck(@floatToInt(i32, enemy.pos.x) - 1, @floatToInt(i32, enemy.pos.y)) and enemy.last_step_direction != Direction.right) {
                    future_target_tile_id = map.tile_indicies.items[@floatToInt(u32, enemy.pos.y) * board_width_in_tiles + @floatToInt(u32, enemy.pos.x) - 1] - 1;
                }
            },
            .up => {
                if (boundsCheck(@floatToInt(i32, enemy.pos.x), @floatToInt(i32, enemy.pos.y) - 1) and enemy.last_step_direction != Direction.down) {
                    future_target_tile_id = map.tile_indicies.items[(@floatToInt(u32, enemy.pos.y) - 1) * board_width_in_tiles + @floatToInt(u32, enemy.pos.x)] - 1;
                }
            },
            .down => {
                if (boundsCheck(@floatToInt(i32, enemy.pos.x), @floatToInt(i32, enemy.pos.y) + 1) and enemy.last_step_direction != Direction.up) {
                    future_target_tile_id = map.tile_indicies.items[(@floatToInt(u32, enemy.pos.y) + 1) * board_width_in_tiles + @floatToInt(u32, enemy.pos.x)] - 1;
                }
            },
        }

        if ((future_target_tile_id != null) and tileset.isTrackTile(future_target_tile_id.?)) {
            break;
        }
    }

    std.debug.assert(enemy.direction != current_direction);
    updateEnemy(tileset, map, enemy);
}

inline fn iProjectionVector() rl.Vector2 {
    return rl.Vector2{ .x = @intToFloat(f32, sprite_width * @floatToInt(c_int, scale_factor)) * 0.5, .y = @intToFloat(f32, sprite_height * @floatToInt(c_int, scale_factor)) * 0.25 };
}

inline fn jProjectionVector() rl.Vector2 {
    return rl.Vector2{ .x = -1 * @intToFloat(f32, sprite_width * @floatToInt(c_int, scale_factor)) * 0.5, .y = @intToFloat(f32, sprite_height * @floatToInt(c_int, scale_factor)) * 0.25 };
}

fn isoProjectBase(x: f32, y: f32, z: f32) rl.Vector2 {
    const i_iso_trans = iProjectionVector();
    const j_iso_trans = jProjectionVector();
    const input = rl.Vector2{ .x = x - z, .y = y - z };
    var out = rl.Vector2{
        .x = input.x * i_iso_trans.x + input.y * j_iso_trans.x,
        .y = input.x * i_iso_trans.y + input.y * j_iso_trans.y,
    };
    return out;
}

fn isoProject(x: f32, y: f32, z: f32) rl.Vector2 {
    var out = isoProjectBase(x, y, z);

    const screen_offset = rl.Vector2{ .x = @intToFloat(f32, rl.GetScreenWidth()) / 2 - sprite_width * scale_factor / 2, .y = (@intToFloat(f32, rl.GetScreenHeight()) - @intToFloat(f32, screenSpaceBoardHeight())) / 2 };

    out.x += screen_offset.x + board_translation.x;
    out.y += screen_offset.y + board_translation.y;

    return out;
}

fn isoProjectInverted(screen_space_x: f32, screen_space_y: f32, tile_space_z: f32) rl.Vector2 {
    const i_iso_trans = iProjectionVector();
    const j_iso_trans = jProjectionVector();

    const screen_offset = rl.Vector2{ .x = @intToFloat(f32, rl.GetScreenWidth()) / 2 - sprite_width * scale_factor / 2, .y = (@intToFloat(f32, rl.GetScreenHeight()) - @intToFloat(f32, screenSpaceBoardHeight())) / 2 };

    const input = rl.Vector2{ .x = screen_space_x - screen_offset.x - board_translation.x, .y = screen_space_y - screen_offset.y - board_translation.y };

    const det = 1 / (i_iso_trans.x * j_iso_trans.y - j_iso_trans.x * i_iso_trans.y);
    const i_invert_iso_trans = rl.Vector2{ .x = j_iso_trans.y * det, .y = i_iso_trans.y * det * -1 };
    const j_invert_iso_trans = rl.Vector2{ .x = j_iso_trans.x * det * -1, .y = i_iso_trans.x * det };

    return rl.Vector2{
        .x = (input.x * i_invert_iso_trans.x + input.y * j_invert_iso_trans.x) + tile_space_z,
        .y = (input.x * i_invert_iso_trans.y + input.y * j_invert_iso_trans.y) + tile_space_z,
    };
}

fn drawTile(tileset: *Tileset, tile_id: u16, dest_pos: rl.Vector2, this_scale_factor: f32, tint: rl.Color) void {
    const dest_rect = rl.Rectangle{
        .x = dest_pos.x,
        .y = dest_pos.y,
        .width = sprite_width * this_scale_factor,
        .height = sprite_height * this_scale_factor,
    };

    const target_tile_row = @divTrunc(tile_id, tileset.columns);
    const target_tile_column = @mod(tile_id, tileset.columns);
    const source_rect = rl.Rectangle{
        .x = @intToFloat(f32, target_tile_column * sprite_width),
        .y = @intToFloat(f32, target_tile_row * sprite_height),
        .width = sprite_width,
        .height = sprite_height,
    };

    rl.DrawTexturePro(tileset.tex, source_rect, dest_rect, .{ .x = 0, .y = 0 }, 0, tint);
}

fn drawBoard(board_map: *Map, tileset: *Tileset, selected_tile_x: i32, selected_tile_y: i32, selected_tower: ?*Tower, tower_index_being_placed: i32) void {
    var tile_y: i32 = 0;
    while (tile_y < board_height_in_tiles) : (tile_y += 1) {
        var tile_x: i32 = 0;
        while (tile_x < board_width_in_tiles) : (tile_x += 1) {
            var dest_pos = isoProject(@intToFloat(f32, tile_x), @intToFloat(f32, tile_y), 0);
            if (tile_x == selected_tile_x and tile_y == selected_tile_y) {
                dest_pos.y -= 4 * scale_factor;
            }
            const tile_id = @intCast(u16, board_map.tileIDFromCoord(@intCast(u16, tile_x), @intCast(u16, tile_y)) orelse continue);
            var tile_color = rl.WHITE;
            if (selected_tower != null) {
                const range = towers_data[@enumToInt(selected_tower.?.kind)].range;
                if (std.math.absCast(tile_x - @intCast(i32, selected_tower.?.tile_x)) + std.math.absCast(tile_y - @intCast(i32, selected_tower.?.tile_y)) <= range) {
                    tile_color = rl.GRAY;
                }
            } else if (tower_index_being_placed >= 0) {
                const range = towers_data[@intCast(u32, tower_index_being_placed)].range;
                if (std.math.absCast(tile_x - @intCast(i32, selected_tile_x)) + std.math.absCast(tile_y - @intCast(i32, selected_tile_y)) <= range) {
                    tile_color = rl.GRAY;
                }
            }
            drawTile(tileset, tile_id, dest_pos, scale_factor, tile_color);
        }
    }
}

fn drawTitleScreenBoard(board_map: *Map, tileset: *Tileset, time_in_seconds: f32) void {
    var tile_y: i32 = 0;
    while (tile_y < board_height_in_tiles) : (tile_y += 1) {
        var tile_x: i32 = 0;
        while (tile_x < board_width_in_tiles) : (tile_x += 1) {
            var dest_pos = isoProject(@intToFloat(f32, tile_x), @intToFloat(f32, tile_y), @sin(time_in_seconds + @intToFloat(f32, tile_y)) / 5 + @cos(time_in_seconds - @intToFloat(f32, tile_x)) / 5);
            const tile_id = @intCast(u16, board_map.tileIDFromCoord(@intCast(u16, tile_x), @intCast(u16, tile_y)) orelse continue);
            var tile_color = rl.WHITE;
            drawTile(tileset, tile_id, dest_pos, scale_factor, tile_color);
        }
    }
}

fn drawBackground(screen_dim: rl.Vector2, background_offset: f32) void {
    rl.ClearBackground(color_off_white);
    var i: i32 = 0; // NOTE(caleb): Don't look to closely at these numbers. They will hurt your eyes.
    while (i < 18) : (i += 1) {
        const start_pos = rl.Vector2{ .x = -40, .y = @intToFloat(f32, i * 120 + @floatToInt(i32, background_offset) - 80) };
        const end_pos = rl.Vector2{ .x = screen_dim.x + 40, .y = @intToFloat(f32, i * 120 - 440) + background_offset };
        rl.DrawLineEx(start_pos, end_pos, 60, color_off_black);
    }
}

fn drawSprites(fba: *FixedBufferAllocator, tileset: *Tileset, debug_hit_boxes: bool, debug_projectile: bool, towers: *ArrayList(Tower), alive_enemies: *ArrayList(Enemy), dead_enemies: *ArrayList(DeadEnemy), projectiles: *ArrayList(Projectile), selected_tile_x: i32, selected_tile_y: i32, tower_index_being_placed: i32, tba_anim_frame: u8) !void {
    fba.reset();
    var draw_list = std.ArrayList(DrawBufferEntry).init(fba.allocator());

    var entry_index: u32 = 0;
    while (entry_index < towers.items.len + alive_enemies.items.len) : (entry_index += 1) {
        var added_entries: u8 = 0;
        var new_entries: [3]DrawBufferEntry = undefined;

        if (towers.items.len > entry_index) {
            const tower = towers.items[entry_index];
            new_entries[added_entries] = DrawBufferEntry{
                .tile_pos = rl.Vector2{
                    .x = @intToFloat(f32, tower.tile_x),
                    .y = @intToFloat(f32, tower.tile_y),
                },
                .ts_id = towers_data[@enumToInt(tower.kind)].tile_id + @enumToInt(tower.direction) * 4 + tower.anim_frame,
            };
            added_entries += 1;
        }

        if (alive_enemies.items.len > entry_index) {
            const enemy = alive_enemies.items[entry_index];
            new_entries[added_entries] = DrawBufferEntry{
                .tile_pos = rl.Vector2{
                    .x = enemy.pos.x,
                    .y = enemy.pos.y,
                },
                .ts_id = enemies_data[@enumToInt(enemy.kind)].tile_id + @enumToInt(enemy.direction) * 4 + enemy.anim_frame,
            };
            added_entries += 1;
        }

        if (dead_enemies.items.len > entry_index) {
            const dead_enemy = dead_enemies.items[entry_index];
            new_entries[added_entries] = DrawBufferEntry{
                .tile_pos = rl.Vector2{
                    .x = dead_enemy.pos.x,
                    .y = dead_enemy.pos.y,
                },
                .ts_id = tileset.tile_name_to_id.get(hashString("death_anim")).? + dead_enemy.anim_frame,
            };
            added_entries += 1;
        }

        for (new_entries[0..added_entries]) |new_entry| {
            var did_insert_entry = false;
            for (draw_list.items) |draw_list_entry, curr_entry_index| {
                if ((new_entry.tile_pos.y < draw_list_entry.tile_pos.y) or
                    (new_entry.tile_pos.y == draw_list_entry.tile_pos.y and new_entry.tile_pos.x < draw_list_entry.tile_pos.x))
                {
                    try draw_list.insert(curr_entry_index, new_entry);
                    did_insert_entry = true;
                    break;
                }
            }
            if (!did_insert_entry) {
                try draw_list.append(new_entry);
            }
        }
    }

    for (draw_list.items) |entry| {
        var dest_pos = isoProject(entry.tile_pos.x, entry.tile_pos.y, 1);
        if ((@floatToInt(i32, entry.tile_pos.x) == selected_tile_x) and
            (@floatToInt(i32, entry.tile_pos.y) == selected_tile_y))
        {
            dest_pos.y -= 4 * scale_factor;
        }
        drawTile(tileset, @intCast(u16, entry.ts_id), dest_pos, scale_factor, rl.WHITE);
    }

    if (debug_hit_boxes) {
        for (alive_enemies.items) |enemy| {
            for (enemy.colliders) |collider| {
                var dest_pos = isoProject(collider.x, collider.y, 1);
                const dest_rec = rl.Rectangle{
                    .x = dest_pos.x,
                    .y = dest_pos.y,
                    .width = collider.width * scale_factor,
                    .height = collider.height * scale_factor,
                };
                rl.DrawRectangleLinesEx(dest_rec, 1, rl.Color{ .r = 0, .g = 0, .b = 255, .a = 255 });
            }
        }
    }

    for (projectiles.items) |projectile| {
        var dest_pos = isoProject(projectile.pos.x, projectile.pos.y, 1);
        switch (projectile.kind) {
            .bullet => {
                const dest_rect = rl.Rectangle{
                    .x = dest_pos.x,
                    .y = dest_pos.y,
                    .width = 2 * scale_factor,
                    .height = 2 * scale_factor,
                };
                rl.DrawRectanglePro(dest_rect, .{ .x = 0, .y = 0 }, 0, rl.Color{ .r = 34, .g = 35, .b = 35, .a = 255 });
            },
            .coin => {
                drawTile(tileset, tileset.tile_name_to_id.get(hashString("money_icon")).?, dest_pos, scale_factor / 2, rl.WHITE);
            },
        }

        if (debug_projectile) {
            const start_pos = rl.Vector2{
                .x = projectile.start.x,
                .y = projectile.start.y,
            };
            var projected_start = isoProject(start_pos.x, start_pos.y, 1);
            var projected_end = isoProject(projectile.target.x, projectile.target.y, 1);
            rl.DrawLineV(projected_start, projected_end, rl.Color{ .r = 255, .g = 0, .b = 0, .a = 255 });
        }
    }

    if (tower_index_being_placed >= 0) {
        const tile_id = towers_data[@intCast(u32, tower_index_being_placed)].tile_id + @enumToInt(Direction.down) * 4 + tba_anim_frame;
        const dest_pos = isoProject(@intToFloat(f32, selected_tile_x), @intToFloat(f32, selected_tile_y), 1);
        drawTile(tileset, @intCast(u16, tile_id), dest_pos, scale_factor, rl.WHITE);
    }
}

fn drawDebugTextInfo(font: *rl.Font, game_state: *GameState, selected_tile_pos: rl.Vector2, screen_dim: rl.Vector2) !void {
    var strz_buffer: [256]u8 = undefined;
    var y_offset: f32 = 0;

    const fps_strz = try std.fmt.bufPrintZ(&strz_buffer, "FPS: {d}", .{rl.GetFPS()});
    y_offset += rl.MeasureTextEx(font.*, @ptrCast([*c]const u8, fps_strz), default_font_size, font_spacing).y;
    rl.DrawTextEx(font.*, @ptrCast([*c]const u8, fps_strz), rl.Vector2{ .x = 0, .y = screen_dim.y - y_offset }, default_font_size, font_spacing, rl.Color{ .r = 255, .g = 0, .b = 0, .a = 255 });

    const tower_count_strz = try std.fmt.bufPrintZ(&strz_buffer, "Tower count: {d}", .{game_state.towers.items.len});
    y_offset += rl.MeasureTextEx(font.*, @ptrCast([*c]const u8, tower_count_strz), default_font_size, font_spacing).y;
    rl.DrawTextEx(font.*, @ptrCast([*c]const u8, tower_count_strz), rl.Vector2{ .x = 0, .y = screen_dim.y - y_offset }, default_font_size, font_spacing, rl.Color{ .r = 255, .g = 0, .b = 0, .a = 255 });

    const projectile_count_strz = try std.fmt.bufPrintZ(&strz_buffer, "Projectile count: {d}", .{game_state.projectiles.items.len});
    y_offset += rl.MeasureTextEx(font.*, @ptrCast([*c]const u8, projectile_count_strz), default_font_size, font_spacing).y;
    rl.DrawTextEx(font.*, @ptrCast([*c]const u8, projectile_count_strz), rl.Vector2{ .x = 0, .y = screen_dim.y - y_offset }, default_font_size, font_spacing, rl.Color{ .r = 255, .g = 0, .b = 0, .a = 255 });

    const enemy_count_strz = try std.fmt.bufPrintZ(&strz_buffer, "Enemy count: {d}", .{game_state.alive_enemies.items.len});
    y_offset += rl.MeasureTextEx(font.*, @ptrCast([*c]const u8, enemy_count_strz), default_font_size, font_spacing).y;
    rl.DrawTextEx(font.*, @ptrCast([*c]const u8, enemy_count_strz), rl.Vector2{ .x = 0, .y = screen_dim.y - y_offset }, default_font_size, font_spacing, rl.Color{ .r = 255, .g = 0, .b = 0, .a = 255 });

    const mouse_tile_space_strz = try std.fmt.bufPrintZ(&strz_buffer, "Tile-space pos: ({d:.2}, {d:.2})", .{ selected_tile_pos.x, selected_tile_pos.y });
    y_offset += rl.MeasureTextEx(font.*, @ptrCast([*c]const u8, mouse_tile_space_strz), default_font_size, font_spacing).y;
    rl.DrawTextEx(font.*, @ptrCast([*c]const u8, mouse_tile_space_strz), rl.Vector2{ .x = 0, .y = screen_dim.y - y_offset }, default_font_size, font_spacing, rl.Color{ .r = 255, .g = 0, .b = 0, .a = 255 });
}

inline fn drawDebugOrigin(screen_mid: rl.Vector2) void {
    rl.DrawLineEx(screen_mid, rlm.Vector2Add(screen_mid, board_translation), 2, rl.Color{ .r = 0, .g = 255, .b = 0, .a = 255 });
}

fn drawStatusBar(font: *rl.Font, tileset: *Tileset, money: i32, hp: i32, round: u32, money_change: *ArrayList(StatusChangeEntry), hp_change: *ArrayList(StatusChangeEntry)) !void {
    // NOTE(caleb): If you plan on adding more UI in the future this fn will need
    //    refactoring as almost all of the dim/pos calculations here were me just punching
    //    in numbers until I got something that looked about right...

    var strz_buffer: [256]u8 = undefined;

    var money_strz = try std.fmt.bufPrintZ(&strz_buffer, "{d}", .{money});
    const money_strz_dim = rl.MeasureTextEx(font.*, @ptrCast([*c]const u8, money_strz), default_font_size, font_spacing);

    const hp_strz_start = money_strz.len + 1;
    const hp_strz = try std.fmt.bufPrintZ(strz_buffer[hp_strz_start..], "{d}", .{hp});
    const hp_strz_dim = rl.MeasureTextEx(font.*, @ptrCast([*c]const u8, hp_strz), default_font_size, font_spacing);

    const round_strz_start = hp_strz_start + hp_strz.len + 1;
    const round_strz = try std.fmt.bufPrintZ(strz_buffer[round_strz_start..], "{d}/20", .{round});
    const round_strz_dim = rl.MeasureTextEx(font.*, @ptrCast([*c]const u8, round_strz), default_font_size, font_spacing);

    const money_sprite_offset_y = 9;
    const money_sprite_offset_x = 6;
    const money_status_rec = rl.Rectangle{
        .x = ((initial_scale_factor / 2) * (sprite_width - money_sprite_offset_x)) / 2,
        .y = ((initial_scale_factor / 2) * (sprite_height - money_sprite_offset_y) - (initial_scale_factor / 2) * (sprite_height - money_sprite_offset_y) * 0.60) / 2.0,
        .width = (initial_scale_factor / 2) * (sprite_width - money_sprite_offset_x) + money_strz_dim.x,
        .height = (initial_scale_factor / 2) * (sprite_height - money_sprite_offset_y) * 0.60,
    };

    rl.DrawRectangleRounded(money_status_rec, 10, 4, color_off_white);
    rl.DrawRectangleRoundedLines(money_status_rec, 10, 4, 2, color_off_black);
    drawTile(tileset, tileset.tile_name_to_id.get(hashString("money_icon")).?, rl.Vector2{ .x = -(initial_scale_factor / 2) * money_sprite_offset_x, .y = -(initial_scale_factor / 2) * money_sprite_offset_y }, initial_scale_factor / 2, rl.WHITE);
    rl.DrawTextEx(font.*, @ptrCast([*c]const u8, money_strz), rl.Vector2{ .x = (initial_scale_factor / 2) * (sprite_width - money_sprite_offset_x), .y = money_status_rec.height / 2 }, default_font_size, font_spacing, color_off_black);

    const hp_sprite_offset_y = 9;
    const hp_sprite_offset_x = 4;
    const hp_status_rec = rl.Rectangle{
        .x = ((initial_scale_factor / 2) * (sprite_width - hp_sprite_offset_x)) / 2,
        .y = ((initial_scale_factor / 2) * (sprite_height - hp_sprite_offset_y) - (initial_scale_factor / 2) * (sprite_height - hp_sprite_offset_y) * 0.60) / 2.0 + (sprite_height - hp_sprite_offset_y) * (initial_scale_factor / 2),
        .width = (initial_scale_factor / 2) * (sprite_width - hp_sprite_offset_x) + hp_strz_dim.x,
        .height = (initial_scale_factor / 2) * (sprite_height - hp_sprite_offset_y) * 0.60,
    };

    rl.DrawRectangleRounded(hp_status_rec, 10, 4, color_off_white);
    rl.DrawRectangleRoundedLines(hp_status_rec, 10, 4, 2, color_off_black);
    drawTile(tileset, tileset.tile_name_to_id.get(hashString("health_icon")).?, rl.Vector2{ .x = -(initial_scale_factor / 2) * hp_sprite_offset_x, .y = -(initial_scale_factor / 2) * hp_sprite_offset_y + (sprite_height - hp_sprite_offset_y) * (initial_scale_factor / 2) }, initial_scale_factor / 2, rl.WHITE);
    rl.DrawTextEx(font.*, @ptrCast([*c]const u8, hp_strz), rl.Vector2{ .x = (initial_scale_factor / 2) * (sprite_width - hp_sprite_offset_x), .y = hp_status_rec.height / 2 + (sprite_height - hp_sprite_offset_y) * (initial_scale_factor / 2) }, default_font_size, font_spacing, color_off_black);

    const round_sprite_offset_x = 0;
    const round_sprite_offset_y = 14;
    const round_status_rec = rl.Rectangle{
        .x = ((initial_scale_factor / 2) * (sprite_width - round_sprite_offset_x)) / 2,
        .y = ((initial_scale_factor / 2) * (sprite_height - round_sprite_offset_y) - (initial_scale_factor / 2) * (sprite_height - round_sprite_offset_y) * 0.60) / 2.0 + (sprite_height - round_sprite_offset_y) * (initial_scale_factor / 2) * 2.6,
        .width = (initial_scale_factor / 2) * (sprite_width - round_sprite_offset_x) + round_strz_dim.x,
        .height = (initial_scale_factor / 2) * (sprite_height - hp_sprite_offset_y) * 0.60,
    };

    rl.DrawRectangleRounded(round_status_rec, 10, 4, color_off_white);
    rl.DrawRectangleRoundedLines(round_status_rec, 10, 4, 2, color_off_black);
    drawTile(tileset, tileset.tile_name_to_id.get(hashString("round_icon")).?, rl.Vector2{ .x = -(initial_scale_factor / 2) * round_sprite_offset_x, .y = -(initial_scale_factor / 2) * round_sprite_offset_y + (sprite_height - round_sprite_offset_y) * (initial_scale_factor / 2) * 2.7 }, initial_scale_factor / 2, rl.WHITE);
    rl.DrawTextEx(font.*, @ptrCast([*c]const u8, round_strz), rl.Vector2{ .x = (initial_scale_factor / 2) * (sprite_width - round_sprite_offset_x) + round_strz_dim.x / 5, .y = round_status_rec.height / 2 + (sprite_height - round_sprite_offset_y) * (initial_scale_factor / 2) * 2.6 }, default_font_size, font_spacing, color_off_black);

    const sign_width = rl.MeasureTextEx(font.*, @ptrCast([*c]const u8, try std.fmt.bufPrintZ(&strz_buffer, "-", .{})), default_font_size, font_spacing).x;
    for (money_change.items) |money_change_entry| {
        var change_strz: [:0]u8 = undefined;
        if (money_change_entry.d_value > 0) {
            change_strz = try std.fmt.bufPrintZ(&strz_buffer, "+{d}", .{money_change_entry.d_value});
        } else {
            change_strz = try std.fmt.bufPrintZ(&strz_buffer, "{d}", .{money_change_entry.d_value});
        }
        rl.DrawTextEx(font.*, @ptrCast([*c]const u8, change_strz), rl.Vector2{ .x = (initial_scale_factor / 2) * (sprite_width - money_sprite_offset_x) - sign_width, .y = money_status_rec.height / 2 + money_change_entry.d_pos.y }, default_font_size, font_spacing, rl.Color{ .r = color_off_black.r, .g = color_off_black.g, .b = color_off_black.b, .a = @floatToInt(u8, @max(0, 255 - @round(money_change_entry.d_pos.y) * 10)) });
    }

    for (hp_change.items) |hp_change_entry| {
        var change_strz: [:0]u8 = undefined;
        if (hp_change_entry.d_value > 0) {
            change_strz = try std.fmt.bufPrintZ(&strz_buffer, "+{d}", .{hp_change_entry.d_value});
        } else {
            change_strz = try std.fmt.bufPrintZ(&strz_buffer, "{d}", .{hp_change_entry.d_value});
        }
        rl.DrawTextEx(font.*, @ptrCast([*c]const u8, change_strz), rl.Vector2{ .x = (initial_scale_factor / 2) * (sprite_width - hp_sprite_offset_x) - sign_width, .y = hp_status_rec.y + hp_change_entry.d_pos.y }, default_font_size, font_spacing, rl.Color{ .r = color_off_black.r, .g = color_off_black.g, .b = color_off_black.b, .a = @floatToInt(u8, @max(0, 255 - @round(hp_change_entry.d_pos.y) * 10)) });
    }
}

pub fn main() !void {
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT);
    rl.InitWindow(sprite_width * board_width_in_tiles * @floatToInt(c_int, scale_factor), screenSpaceBoardHeight(), "twr-defns");
    rl.SetWindowState(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE);
    rl.SetWindowState(rl.ConfigFlags.FLAG_VSYNC_HINT);
    rl.SetExitKey(rl.KeyboardKey.KEY_NULL);
    rl.SetTargetFPS(target_fps);
    rl.SetTraceLogLevel(@enumToInt(rl.TraceLogLevel.LOG_ERROR));

    const window_icon = rl.LoadImage("data/images/icon.png");
    rl.SetWindowIcon(window_icon);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ally = arena.allocator();
    var push_buffer = try ally.alloc(u8, 1024 * 10); // 10kb should be enough.
    var fba = std.heap.FixedBufferAllocator.init(push_buffer);

    rl.InitAudioDevice();
    defer rl.CloseAudioDevice();
    var music = rl.LoadMusicStream("data/music/grasslands.wav");
    rl.SetMasterVolume(1);
    rl.SetMusicVolume(music, 1);
    rl.PlayMusicStream(music);

    const shoot_sound = rl.LoadSound("data/sfx/shoot.wav");
    const hit_sound = rl.LoadSound("data/sfx/hit.wav");
    const dead_sound = rl.LoadSound("data/sfx/ded.wav");
    rl.SetSoundVolume(shoot_sound, 0.5);
    rl.SetSoundVolume(hit_sound, 0.2);
    rl.SetSoundVolume(dead_sound, 0.2);

    var font = rl.LoadFont("data/PICO-8_mono.ttf");
    var splash_text_tex = rl.LoadTexture("data/images/splash_text.png");
    var tileset_tex = rl.LoadTexture("data/images/isosheet.png");

    var parser = std.json.Parser.init(ally, false);
    defer parser.deinit();

    var tileset: Tileset = undefined;
    tileset.tex = tileset_tex;
    tileset.tile_name_to_id = AutoHashMap(u64, u16).init(ally);
    {
        const tileset_file = try std.fs.cwd().openFile("data/images/isosheet.tsj", .{});
        defer tileset_file.close();
        var raw_tileset_json = try tileset_file.reader().readAllAlloc(ally, 1024 * 5); // 5kib should be enough
        defer ally.free(raw_tileset_json);

        var parsed_tileset_data = try parser.parse(raw_tileset_json);

        const columns_value = parsed_tileset_data.root.Object.get("columns") orelse unreachable;
        tileset.columns = @intCast(u16, columns_value.Integer);

        const tile_data = parsed_tileset_data.root.Object.get("tiles") orelse unreachable;
        var enemy_id_count: u32 = 0;
        var tower_id_count: u32 = 0;
        for (tile_data.Array.items) |tile| {
            var tile_id = tile.Object.get("id") orelse unreachable;
            var tile_type = tile.Object.get("type") orelse unreachable;

            if (std.mem.eql(u8, tile_type.String, "enemy")) {
                std.debug.assert(enemy_id_count < enemies_data.len);
                enemies_data[enemy_id_count].tile_id = @intCast(u32, tile_id.Integer);
                enemy_id_count += 1;
            } else if (std.mem.eql(u8, tile_type.String, "tower")) {
                std.debug.assert(tower_id_count < towers_data.len);
                towers_data[tower_id_count].tile_id = @intCast(u32, tile_id.Integer);
                tower_id_count += 1;
            } else {
                try tileset.tile_name_to_id.put(hashString(tile_type.String), @intCast(u16, tile_id.Integer));
            }
        }
    }

    var board_map: Map = undefined;
    board_map.tile_indicies = ArrayList(u16).init(ally);
    defer board_map.tile_indicies.deinit();
    {
        const map_file = try std.fs.cwd().openFile("data/map1.tmj", .{});
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
            try board_map.tile_indicies.append(@intCast(u16, tile_index.Integer));
        }

        var tilesets = parsed_map.root.Object.get("tilesets") orelse unreachable;
        std.debug.assert(tilesets.Array.items.len == 1);
        const first_gid = tilesets.Array.items[0].Object.get("firstgid") orelse unreachable;
        board_map.first_gid = @intCast(u16, first_gid.Integer);
    }

    var round_spawn_data: [20]RoundSpawns = undefined;
    for (round_spawn_data) |*rsd_entry|
        rsd_entry.* = std.mem.zeroes(RoundSpawns);
    {
        const round_info_file = try std.fs.cwd().openFile("data/round_info.json", .{});
        defer round_info_file.close();
        var round_info_json = try round_info_file.reader().readAllAlloc(ally, 1024 * 10);
        defer ally.free(round_info_json);

        parser.reset();
        var parsed_round_info = try parser.parse(round_info_json);
        const round_spawn_data_property = parsed_round_info.root.Object.get("round_spawn_data") orelse unreachable;
        for (round_spawn_data_property.Array.items) |group_spawn_data, group_spawn_data_index| {
            for (group_spawn_data.Array.items) |group_spawn_data_entry, group_spawn_data_entry_index| {
                const kind = group_spawn_data_entry.Object.get("kind") orelse unreachable;
                const spawn_count = group_spawn_data_entry.Object.get("spawn_count") orelse unreachable;
                const time_between_spawns_ms = group_spawn_data_entry.Object.get("time_between_spawns_ms") orelse unreachable;

                round_spawn_data[group_spawn_data_index].group_spawn_data[group_spawn_data_entry_index] = GroupSpawnData{
                    .kind = @intToEnum(EnemyKind, @intCast(u32, kind.Integer)),
                    .spawn_count = @intCast(u32, spawn_count.Integer),
                    .time_between_spawns_ms = @intCast(u16, time_between_spawns_ms.Integer),
                };
            }
            round_spawn_data[group_spawn_data_index].unique_enemies_for_this_round = @intCast(u8, group_spawn_data.Array.items.len);
        }
    }

    var game_mode = GameMode.title_screen;
    var game_state: GameState = undefined;
    game_state.reset();
    game_state.towers = ArrayList(Tower).init(ally);
    game_state.alive_enemies = ArrayList(Enemy).init(ally);
    game_state.dead_enemies = ArrayList(DeadEnemy).init(ally);
    game_state.projectiles = ArrayList(Projectile).init(ally);
    game_state.money_change = ArrayList(StatusChangeEntry).init(ally);
    game_state.hp_change = ArrayList(StatusChangeEntry).init(ally);

    var debug_projectile = false;
    var debug_origin = false;
    var debug_hit_boxes = false;
    var debug_text_info = false;

    var bg_offset: f32 = 0;
    var splash_text_pos = rl.Vector2{
        .x = @intToFloat(f32, rl.GetScreenWidth()) / 2 - @intToFloat(f32, splash_text_tex.width) * initial_scale_factor / 2.0,
        .y = -@intToFloat(f32, splash_text_tex.height) * initial_scale_factor,
    };

    var rng = std.rand.DefaultPrng.init(0);
    var hot_button_index: i32 = -1;
    var prev_frame_screen_dim = rl.Vector2{ .x = @intToFloat(f32, rl.GetScreenWidth()), .y = @intToFloat(f32, rl.GetScreenHeight()) };
    var prev_frame_input = Input{ .l_mouse_button_is_down = false, .mouse_pos = rl.Vector2{ .x = 0, .y = 0 } };
    var last_time_ms = rl.GetTime() * 1000;

    var tba_anim_frame: u8 = 0;
    var tba_anim_timer: u8 = 0;

    var enemy_start_tile_y: u16 = 0;
    var enemy_start_tile_x: u16 = 0;
    {
        const track_start_id = tileset.tile_name_to_id.get(hashString("track_start")) orelse unreachable;
        var found_enemy_start_tile = false;
        outer: while (enemy_start_tile_y < board_height_in_tiles) : (enemy_start_tile_y += 1) {
            enemy_start_tile_x = 0;
            while (enemy_start_tile_x < board_width_in_tiles) : (enemy_start_tile_x += 1) {
                const ts_id = board_map.tileIDFromCoord(enemy_start_tile_x, enemy_start_tile_y) orelse continue;
                if ((ts_id) == track_start_id) {
                    found_enemy_start_tile = true;
                    break :outer;
                }
            }
        }
        std.debug.assert(found_enemy_start_tile);
    }

    game_loop: while (!rl.WindowShouldClose()) {
        // Gamemode agnostic updates -------------------------------------------------------------------------
        rl.UpdateMusicStream(music);

        const screen_dim = rl.Vector2{ .x = @intToFloat(f32, rl.GetScreenWidth()), .y = @intToFloat(f32, rl.GetScreenHeight()) };
        const screen_mid = rl.Vector2{
            .x = screen_dim.x / 2,
            .y = screen_dim.y / 2,
        };
        const mouse_pos = rl.GetMousePosition();
        var selected_tile_pos = isoProjectInverted(mouse_pos.x - sprite_width * scale_factor / 2, mouse_pos.y, 0);
        const selected_tile_x = @floatToInt(i32, @floor(selected_tile_pos.x));
        const selected_tile_y = @floatToInt(i32, @floor(selected_tile_pos.y));

        if (rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_MIDDLE))
            board_translation = rlm.Vector2Add(board_translation, rl.GetMouseDelta());

        if (rlm.Vector2Equals(prev_frame_screen_dim, screen_dim) == 0) {
            splash_text_pos = rl.Vector2{
                .x = @intToFloat(f32, rl.GetScreenWidth()) / 2 - @intToFloat(f32, splash_text_tex.width) * initial_scale_factor / 2.0,
                .y = -@intToFloat(f32, splash_text_tex.height) * initial_scale_factor,
            };
        }

        scale_factor = clampf32(scale_factor + @round(rl.GetMouseWheelMove()), 1, 10);
        bg_offset = (bg_offset + 0.25 - @floor(bg_offset)) + @intToFloat(f32, @floatToInt(u32, bg_offset) % 120);

        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_F1)) {
            debug_projectile = !debug_projectile;
            debug_origin = !debug_origin;
            debug_hit_boxes = !debug_hit_boxes;
            debug_text_info = !debug_text_info;
        }

        const time_in_seconds = @floatCast(f32, rl.GetTime());

        switch (game_mode) {
            .title_screen => {
                // Title-screen update -------------------------------------------------------------------------
                const fall_speed_scalar = 4;
                const splash_rec = rl.Rectangle{
                    .x = splash_text_pos.x,
                    .y = splash_text_pos.y,
                    .width = @intToFloat(f32, splash_text_tex.width) * initial_scale_factor,
                    .height = @intToFloat(f32, splash_text_tex.height) * initial_scale_factor,
                };
                var splash_text_in_mid = false;
                var y_offset: f32 = 0;
                if (splash_text_pos.y + @intToFloat(f32, splash_text_tex.height) * initial_scale_factor / 2 <= screen_mid.y - @intToFloat(f32, splash_text_tex.height)) {
                    splash_text_pos.y += 100 * fall_speed_scalar / target_fps;
                } else {
                    splash_text_in_mid = true;
                    y_offset = @sin(time_in_seconds * 10) * 10;
                }

                var button_dest_recs: [2]rl.Rectangle = undefined;
                for (button_dest_recs) |*rec, rec_index| {
                    rec.x = splash_rec.x + sprite_width * initial_scale_factor * @intToFloat(f32, rec_index) +
                        (splash_rec.width - sprite_width * initial_scale_factor * @intToFloat(f32, button_dest_recs.len)) / 2;
                    rec.y = splash_rec.y + splash_rec.height + 10;
                    rec.width = sprite_width * initial_scale_factor;
                    rec.height = sprite_height * initial_scale_factor;

                    if ((rl.CheckCollisionPointRec(mouse_pos, rec.*)) and
                        (!prev_frame_input.l_mouse_button_is_down) and
                        (rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT)))
                    {
                        hot_button_index = @intCast(i32, rec_index);
                    } else if (@intCast(i32, rec_index) == hot_button_index and !rl.CheckCollisionPointRec(mouse_pos, rec.*)) {
                        hot_button_index = -1;
                    }

                    if (@intCast(i32, rec_index) == hot_button_index) {
                        rec.x += sprite_width * initial_scale_factor * 0.1 / 2.0;
                        rec.y += sprite_height * initial_scale_factor * 0.1 / 2.0;
                        rec.width *= 0.9;
                        rec.height *= 0.9;
                    }

                    if (@intCast(i32, rec_index) == hot_button_index and rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT)) {
                        if (rec_index == 0) { // Play button
                            game_state.reset();
                            game_mode = GameMode.running;
                        } else if (rec_index == 1) { // Quit button
                            break :game_loop;
                        }
                    }
                }

                prev_frame_input.mouse_pos = mouse_pos;
                prev_frame_input.l_mouse_button_is_down = rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT);
                prev_frame_screen_dim = screen_dim;

                // Title-screen render -------------------------------------------------------------------------
                rl.BeginDrawing();
                drawBackground(screen_dim, bg_offset);
                drawTitleScreenBoard(&board_map, &tileset, time_in_seconds);
                if (debug_text_info)
                    try drawDebugTextInfo(&font, &game_state, selected_tile_pos, screen_dim);
                if (debug_origin)
                    drawDebugOrigin(screen_mid);
                rl.DrawTextureEx(splash_text_tex, rl.Vector2{ .x = splash_text_pos.x, .y = splash_text_pos.y + y_offset }, 0, initial_scale_factor, rl.WHITE);
                if (splash_text_in_mid) {
                    drawTile(&tileset, tileset.tile_name_to_id.get(hashString("play_button")).?, rl.Vector2{ .x = button_dest_recs[0].x, .y = button_dest_recs[0].y }, initial_scale_factor, rl.WHITE);
                    drawTile(&tileset, tileset.tile_name_to_id.get(hashString("quit_button")).?, rl.Vector2{ .x = button_dest_recs[1].x, .y = button_dest_recs[1].y }, initial_scale_factor, rl.WHITE);
                }
                rl.EndDrawing();
            },
            .game_end => {
                // Game end update -------------------------------------------------------------------------
                var strz_buffer: [256]u8 = undefined;
                const game_end_font_size = 18;
                var game_end_strz: [:0]u8 = undefined;
                if (game_state.hp > 0) {
                    game_end_strz = try std.fmt.bufPrintZ(&strz_buffer, "VICTORY!", .{});
                } else {
                    game_end_strz = try std.fmt.bufPrintZ(&strz_buffer, "GAME OVER! -- round: {d}", .{game_state.round});
                }
                const game_end_strz_dim = rl.MeasureTextEx(font, @ptrCast([*c]const u8, game_end_strz), game_end_font_size, font_spacing);
                const start_y = screen_mid.y + @sin(time_in_seconds * 10) * 5;
                const game_end_strz_pos = rl.Vector2{ .x = screen_mid.x - game_end_strz_dim.x / 2, .y = start_y };
                const game_end_popup_rec = rl.Rectangle{
                    .x = screen_mid.x - game_end_strz_dim.x / 2 - (sprite_width * initial_scale_factor * 3 - game_end_strz_dim.x) / 2,
                    .y = game_end_strz_pos.y,
                    .width = sprite_width * initial_scale_factor * 3,
                    .height = game_end_strz_dim.y + sprite_height * initial_scale_factor,
                };

                var button_dest_recs: [3]rl.Rectangle = undefined;
                for (button_dest_recs) |*rec, rec_index| {
                    rec.x = game_end_popup_rec.x + sprite_width * initial_scale_factor * @intToFloat(f32, rec_index);
                    rec.y = game_end_strz_pos.y + game_end_strz_dim.y;
                    rec.width = sprite_width * initial_scale_factor;
                    rec.height = sprite_height * initial_scale_factor;

                    if ((rl.CheckCollisionPointRec(mouse_pos, rec.*)) and
                        (!prev_frame_input.l_mouse_button_is_down) and
                        (rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT)))
                    {
                        hot_button_index = @intCast(i32, rec_index);
                    } else if (@intCast(i32, rec_index) == hot_button_index and !rl.CheckCollisionPointRec(mouse_pos, rec.*)) {
                        hot_button_index = -1;
                    }

                    if (@intCast(i32, rec_index) == hot_button_index) {
                        rec.x += sprite_width * initial_scale_factor * 0.1 / 2.0;
                        rec.y += sprite_height * initial_scale_factor * 0.1 / 2.0;
                        rec.width *= 0.9;
                        rec.height *= 0.9;
                    }

                    if (@intCast(i32, rec_index) == hot_button_index and rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT)) {
                        if (rec_index == 0) { // Restart
                            game_state.reset();
                            game_mode = GameMode.running;
                        } else if (rec_index == 1) { // Home
                            game_state.reset();
                            game_mode = GameMode.title_screen;
                            splash_text_pos = rl.Vector2{
                                .x = @intToFloat(f32, rl.GetScreenWidth()) / 2 - @intToFloat(f32, splash_text_tex.width) * initial_scale_factor / 2.0,
                                .y = -@intToFloat(f32, splash_text_tex.height) * initial_scale_factor,
                            };
                        } else if (rec_index == 2) { // Quit
                            break :game_loop;
                        }
                    }
                }

                prev_frame_input.mouse_pos = mouse_pos;
                prev_frame_input.l_mouse_button_is_down = rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT);
                prev_frame_screen_dim = screen_dim;

                // Game over render -------------------------------------------------------------------------
                rl.BeginDrawing();
                drawBackground(screen_dim, bg_offset);
                drawBoard(&board_map, &tileset, selected_tile_x, selected_tile_y, game_state.selected_tower, game_state.tower_index_being_placed);
                try drawSprites(&fba, &tileset, debug_hit_boxes, debug_projectile, &game_state.towers, &game_state.alive_enemies, &game_state.dead_enemies, &game_state.projectiles, selected_tile_x, selected_tile_y, game_state.tower_index_being_placed, tba_anim_frame);
                if (debug_text_info)
                    try drawDebugTextInfo(&font, &game_state, selected_tile_pos, screen_dim);
                if (debug_origin)
                    drawDebugOrigin(screen_mid);
                try drawStatusBar(&font, &tileset, game_state.money, game_state.hp, game_state.round, &game_state.money_change, &game_state.hp_change);
                rl.DrawTextEx(font, @ptrCast([*c]const u8, game_end_strz), game_end_strz_pos, game_end_font_size, font_spacing, color_off_black);
                drawTile(&tileset, tileset.tile_name_to_id.get(hashString("retry_button")).?, rl.Vector2{ .x = button_dest_recs[0].x, .y = button_dest_recs[0].y }, initial_scale_factor, rl.WHITE);
                drawTile(&tileset, tileset.tile_name_to_id.get(hashString("menu_button")).?, rl.Vector2{ .x = button_dest_recs[1].x, .y = button_dest_recs[1].y }, initial_scale_factor, rl.WHITE);
                drawTile(&tileset, tileset.tile_name_to_id.get(hashString("quit_button")).?, rl.Vector2{ .x = button_dest_recs[2].x, .y = button_dest_recs[2].y }, initial_scale_factor, rl.WHITE);
                rl.EndDrawing();
            },
            .running => {
                const dtime_ms = @floatCast(f32, rl.GetTime() * 1000 - last_time_ms);

                // Towers -------------------------------------------------------------------------
                for (game_state.towers.items) |*tower| {
                    tower.anim_timer += 1;
                    if (tower.anim_timer >= @divTrunc(target_fps, anim_frames_speed)) {
                        tower.anim_timer = 0;
                        tower.anim_frame += 1;
                        if (tower.anim_frame > 3)
                            tower.anim_frame = 0;
                    }
                    tower.fire_rate_timer += 1;
                    if (tower.fire_rate_timer >= target_fps / tower.fire_rate and game_state.round_in_progress) {
                        tower.fire_rate_timer = 0;
                        switch (tower.kind) {
                            .floating_eye => {
                                for (game_state.alive_enemies.items) |*enemy| {
                                    const enemy_tile_x = @floatToInt(i32, @floor(enemy.pos.x));
                                    const enemy_tile_y = @floatToInt(i32, @floor(enemy.pos.y));
                                    if (std.math.absCast(enemy_tile_x - @intCast(i32, tower.tile_x)) + std.math.absCast(enemy_tile_y - @intCast(i32, tower.tile_y)) <= towers_data[@enumToInt(tower.kind)].range) {
                                        if (enemy_tile_y < tower.tile_y and enemy_tile_x == tower.tile_x) {
                                            tower.direction = Direction.up;
                                        } else if (enemy_tile_x > tower.tile_x) {
                                            tower.direction = Direction.right;
                                        } else if (enemy_tile_y > tower.tile_y and enemy_tile_x == tower.tile_x) {
                                            tower.direction = Direction.down;
                                        } else if (enemy_tile_x < tower.tile_x) {
                                            tower.direction = Direction.left;
                                        }
                                        const tower_pos = rl.Vector2{ .x = @intToFloat(f32, tower.tile_x), .y = @intToFloat(f32, tower.tile_y) };
                                        var screen_space_start = isoProject(tower_pos.x, tower_pos.y, 0);
                                        screen_space_start.x += sprite_width * scale_factor / 2;
                                        screen_space_start.y -= sprite_height * scale_factor / 4; // TODO(caleb): Use sprite offsets here
                                        const tile_space_start = isoProjectInverted(screen_space_start.x, screen_space_start.y, 1);

                                        var screen_space_target = isoProject(enemy.pos.x, enemy.pos.y, 0);
                                        screen_space_target.x += sprite_width * scale_factor / 2;
                                        const tile_space_target = isoProjectInverted(screen_space_target.x, screen_space_target.y, 1);

                                        const new_projectile = Projectile{
                                            .kind = ProjectileKind.bullet,
                                            .direction = rlm.Vector2Normalize(rlm.Vector2Subtract(tile_space_target, tile_space_start)),
                                            .target = tile_space_target,
                                            .start = tile_space_start,
                                            .pos = tile_space_start,
                                            .speed = tower.fire_speed / target_fps,
                                            .damage = towers_data[@enumToInt(tower.kind)].damage,
                                        };
                                        try game_state.projectiles.append(new_projectile);
                                        break;
                                    }
                                }
                            },
                            .bank => {
                                if (rng.random().uintLessThan(u8, 2) == 1) { // 1 in 3 chance to gen a coin
                                    var tile_space_start = rl.Vector2{ .x = @intToFloat(f32, tower.tile_x), .y = @intToFloat(f32, tower.tile_y) };
                                    var screen_space_start = isoProject(tile_space_start.x, tile_space_start.y, 1);
                                    screen_space_start.x += sprite_width * scale_factor / 2;
                                    screen_space_start.y += sprite_height * scale_factor / 2;
                                    tile_space_start = isoProjectInverted(screen_space_start.x, screen_space_start.y, 1);

                                    const tile_space_target = rlm.Vector2Add(tile_space_start, rl.Vector2{ .x = @cos(time_in_seconds), .y = @sin(time_in_seconds) });
                                    const new_projectile = Projectile{
                                        .kind = ProjectileKind.coin,
                                        .direction = rlm.Vector2Normalize(rlm.Vector2Subtract(tile_space_target, tile_space_start)),
                                        .target = tile_space_target,
                                        .start = tile_space_start,
                                        .pos = tile_space_start,
                                        .speed = @intToFloat(f32, rng.random().intRangeAtMost(u8, @floatToInt(u8, @round(tower.fire_speed)), @floatToInt(u8, tower.fire_speed) + 3)) / target_fps,
                                        .damage = towers_data[@enumToInt(tower.kind)].damage,
                                    };
                                    try game_state.projectiles.append(new_projectile);
                                }
                            },
                        }
                    }
                }

                var clicked_on_a_tower = false;
                if (rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_RIGHT)) {
                    if ((selected_tile_x < board_width_in_tiles) and (selected_tile_y < board_height_in_tiles) and
                        (selected_tile_x >= 0) and (selected_tile_y >= 0))
                    {
                        var tower_index: i32 = 0;
                        while (tower_index < game_state.towers.items.len) : (tower_index += 1) {
                            const tower = &game_state.towers.items[@intCast(u32, tower_index)];
                            if ((tower.tile_x == @intCast(u32, selected_tile_x)) and
                                (tower.tile_y == @intCast(u32, selected_tile_y)))
                            {
                                if (rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_RIGHT)) { // Sell tower
                                    game_state.money += @intCast(i32, towers_data[@enumToInt(tower.kind)].cost / 2);
                                    try game_state.money_change.append(StatusChangeEntry{ .d_value = @intCast(i32, towers_data[@enumToInt(tower.kind)].cost / 2), .d_pos = rl.Vector2{ .x = 0, .y = 0 } });
                                    _ = game_state.towers.orderedRemove(@intCast(u32, tower_index));
                                    tower_index -= 1;
                                    continue;
                                } else { // Select tower
                                    clicked_on_a_tower = true;
                                    game_state.selected_tower = tower;
                                }
                                break;
                            }
                        }
                    }
                    if (!clicked_on_a_tower) {
                        game_state.selected_tower = null;
                    }
                }

                if (game_state.tower_index_being_placed >= 0 and rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT)) {
                    if ((selected_tile_x < board_width_in_tiles) and (selected_tile_y < board_height_in_tiles) and
                        (selected_tile_x >= 0) and (selected_tile_y >= 0))
                    {
                        const tile_id = board_map.tileIDFromCoord(@intCast(u16, selected_tile_x), @intCast(u16, selected_tile_y)).?;
                        if (!tileset.isTrackTile(tile_id) and !clicked_on_a_tower and game_state.money >=
                            @intCast(i32, towers_data[@intCast(u32, game_state.tower_index_being_placed)].cost))
                        {
                            game_state.selected_tower = null;
                            const new_tower = Tower{
                                .kind = @intToEnum(TowerKind, game_state.tower_index_being_placed),
                                .direction = Direction.down,
                                .tile_x = @intCast(u16, selected_tile_x),
                                .tile_y = @intCast(u16, selected_tile_y),
                                .fire_rate = towers_data[@intCast(u32, game_state.tower_index_being_placed)].fire_rate,
                                .fire_speed = towers_data[@intCast(u32, game_state.tower_index_being_placed)].fire_speed,
                                .fire_rate_timer = 0,
                                .anim_frame = 0,
                                .anim_timer = 0,
                            };
                            var did_insert_tower = false;
                            for (game_state.towers.items) |tower, tower_index| {
                                if (tower.tile_y >= new_tower.tile_y) {
                                    try game_state.towers.insert(tower_index, new_tower);
                                    did_insert_tower = true;
                                    break;
                                }
                            }
                            if (!did_insert_tower) {
                                try game_state.towers.append(new_tower);
                            }
                            game_state.money -= @intCast(i32, towers_data[@intCast(u32, game_state.tower_index_being_placed)].cost);
                            try game_state.money_change.append(StatusChangeEntry{ .d_value = -@intCast(i32, towers_data[@intCast(u32, game_state.tower_index_being_placed)].cost), .d_pos = rl.Vector2{ .x = 0, .y = 0 } });
                        }
                    }
                    game_state.tower_index_being_placed = -1;
                }

                // Projectiles -------------------------------------------------------------------------
                var projectile_index: i32 = 0;
                outer: while (projectile_index < game_state.projectiles.items.len) : (projectile_index += 1) {
                    var projectile = &game_state.projectiles.items[@intCast(u32, projectile_index)];
                    var projected_projectile_pos = isoProject(projectile.pos.x, projectile.pos.y, 1);
                    if ((@floor(projectile.pos.x) > board_width_in_tiles * 2) or
                        (@floor(projectile.pos.y) > board_height_in_tiles * 2) or
                        (projectile.pos.x < -board_width_in_tiles) or (projectile.pos.y < -board_height_in_tiles))
                    {
                        _ = game_state.projectiles.orderedRemove(@intCast(u32, projectile_index));
                        projectile_index -= 1;
                        continue;
                    }
                    switch (projectile.kind) {
                        .bullet => {
                            for (game_state.alive_enemies.items) |*enemy| {
                                for (enemy.colliders) |collider| {
                                    const projected_collider_pos = isoProject(collider.x, collider.y, 1);
                                    const projected_collider_rec = rl.Rectangle{
                                        .x = projected_collider_pos.x,
                                        .y = projected_collider_pos.y,
                                        .width = collider.width * scale_factor,
                                        .height = collider.height * scale_factor,
                                    };
                                    const projected_projectile_rec = rl.Rectangle{
                                        .x = projected_projectile_pos.x,
                                        .y = projected_projectile_pos.y,
                                        .width = 2 * scale_factor,
                                        .height = 2 * scale_factor,
                                    };
                                    if (rl.CheckCollisionRecs(projected_projectile_rec, projected_collider_rec)) {
                                        enemy.hp -= @intCast(i32, projectile.damage);
                                        _ = game_state.projectiles.orderedRemove(@intCast(u32, projectile_index));
                                        projectile_index -= 1;
                                        rl.PlaySound(hit_sound);
                                        continue :outer;
                                    }
                                }
                            }
                        },
                        .coin => {
                            projectile.speed = @max(0, projectile.speed - 0.01);
                            if (rl.CheckCollisionPointCircle(mouse_pos, rl.Vector2{ .x = projected_projectile_pos.x + sprite_width * (scale_factor / 2 / 2), .y = projected_projectile_pos.y + sprite_height * (scale_factor / 2 / 2) }, sprite_width * (initial_scale_factor / 2 / 2))) {
                                game_state.money += @intCast(i32, projectile.damage);
                                try game_state.money_change.append(StatusChangeEntry{ .d_value = @intCast(i32, projectile.damage), .d_pos = rl.Vector2{ .x = 0, .y = 0 } });
                                _ = game_state.projectiles.orderedRemove(@intCast(u32, projectile_index));
                                projectile_index -= 1;
                                continue :outer;
                            }
                        },
                    }
                    projectile.pos = rlm.Vector2Add(projectile.pos, rlm.Vector2Scale(projectile.direction, projectile.speed));
                }

                // Enemies -------------------------------------------------------------------------
                if (game_state.round_in_progress) {
                    std.debug.assert(game_state.round > 0);
                    const rsd = round_spawn_data[(game_state.round - 1) % round_spawn_data.len];
                    for (rsd.group_spawn_data[0..rsd.unique_enemies_for_this_round]) |gsd_entry, gsd_index| {
                        if (game_state.round_gsd[gsd_index].spawn_count < gsd_entry.spawn_count) {
                            game_state.round_gsd[gsd_index].time_between_spawns_ms += @floatToInt(u16, dtime_ms);
                            if (game_state.round_gsd[gsd_index].time_between_spawns_ms >= gsd_entry.time_between_spawns_ms) {
                                var new_enemy: Enemy = undefined;
                                new_enemy.kind = gsd_entry.kind;
                                new_enemy.direction = Direction.left; // TODO(caleb): Choose a start direction smartly?
                                new_enemy.last_step_direction = Direction.left;
                                new_enemy.pos = rl.Vector2{ .x = @intToFloat(f32, enemy_start_tile_x), .y = @intToFloat(f32, enemy_start_tile_y) };
                                new_enemy.hp = @intCast(i32, enemies_data[@enumToInt(gsd_entry.kind)].hp);
                                new_enemy.tile_steps_per_second = enemies_data[@enumToInt(gsd_entry.kind)].tile_steps_per_second;
                                new_enemy.tile_step_timer = 0;
                                new_enemy.anim_frame = 0;
                                new_enemy.anim_timer = 0;
                                new_enemy.initColliders();
                                try game_state.alive_enemies.append(new_enemy);

                                game_state.round_gsd[gsd_index].time_between_spawns_ms = 0;
                                game_state.round_gsd[gsd_index].spawn_count += 1;
                            }
                        }
                    }
                }

                var alive_enemy_index: i32 = 0;
                while (alive_enemy_index < game_state.alive_enemies.items.len) : (alive_enemy_index += 1) {
                    var enemy = &game_state.alive_enemies.items[@intCast(u32, alive_enemy_index)];
                    if (enemy.hp <= 0) { // Handle death stuff now
                        rl.PlaySound(dead_sound);
                        game_state.money += @intCast(i32, @enumToInt(enemy.kind)) + 1;
                        try game_state.money_change.append(StatusChangeEntry{ .d_value = @intCast(i32, @enumToInt(enemy.kind)) + 1, .d_pos = rl.Vector2{ .x = 0, .y = 0 } });
                        try game_state.dead_enemies.append(DeadEnemy{ .pos = game_state.alive_enemies.orderedRemove(@intCast(u32, alive_enemy_index)).pos, .anim_frame = 0, .anim_timer = 0 });
                        alive_enemy_index -= 1;
                        continue;
                    } else if (!boundsCheck(@floatToInt(i32, @floor(enemy.pos.x)), @floatToInt(i32, @floor(enemy.pos.y)))) { // End of track
                        game_state.hp = @max(0, game_state.hp - enemy.hp);
                        try game_state.hp_change.append(StatusChangeEntry{ .d_value = -enemy.hp, .d_pos = rl.Vector2{ .x = 0, .y = 0 } });
                        _ = game_state.alive_enemies.orderedRemove(@intCast(u32, alive_enemy_index));
                        alive_enemy_index -= 1;
                        continue;
                    }

                    enemy.anim_timer += 1;
                    if (enemy.anim_timer >= @divTrunc(target_fps, anim_frames_speed)) {
                        enemy.anim_timer = 0;
                        enemy.anim_frame += 1;
                        if (enemy.anim_frame > 3)
                            enemy.anim_frame = 0;
                    }
                    enemy.tile_step_timer += 1;
                    if (enemy.tile_step_timer >= @divTrunc(target_fps, enemy.tile_steps_per_second)) {
                        enemy.tile_step_timer = 0;
                        var i: f32 = 0; // Update n times this frame if needed.
                        while (i < 1) : (i += target_fps / @intToFloat(f32, enemy.tile_steps_per_second))
                            updateEnemy(&tileset, &board_map, enemy);
                    }
                }
                var dead_enemy_index: i32 = 0;
                while (dead_enemy_index < game_state.dead_enemies.items.len) : (dead_enemy_index += 1) {
                    var dead_enemy = &game_state.dead_enemies.items[@intCast(u32, dead_enemy_index)];
                    dead_enemy.anim_timer += 1;
                    if (dead_enemy.anim_timer >= @divTrunc(target_fps, death_anim_frames_speed)) {
                        dead_enemy.anim_timer = 0;
                        dead_enemy.anim_frame += 1;
                    }
                    if (dead_enemy.anim_frame > 3) {
                        _ = game_state.dead_enemies.orderedRemove(@intCast(u32, dead_enemy_index));
                    }
                }

                // Round  -------------------------------------------------------------------------
                var round_start_rec = rl.Rectangle{
                    .x = screen_dim.x - sprite_width * initial_scale_factor,
                    .y = screen_dim.y - sprite_height * initial_scale_factor,
                    .width = sprite_height * initial_scale_factor,
                    .height = sprite_height * initial_scale_factor,
                };
                if (!game_state.round_in_progress) {
                    if ((rl.CheckCollisionPointRec(mouse_pos, round_start_rec)) and
                        (!prev_frame_input.l_mouse_button_is_down) and
                        (rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT)))
                    {
                        hot_button_index = 1; // NOTE(caleb): This can be set to anything
                    } else if (!rl.CheckCollisionPointRec(mouse_pos, round_start_rec)) {
                        hot_button_index = -1;
                    }
                    if (hot_button_index != -1) {
                        round_start_rec.x += sprite_width * initial_scale_factor * 0.1 / 2.0;
                        round_start_rec.y += sprite_height * initial_scale_factor * 0.1 / 2.0;
                        round_start_rec.width *= 0.9;
                        round_start_rec.height *= 0.9;
                    }
                    if (hot_button_index != -1 and rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT)) { // Begin next round
                        hot_button_index = -1;
                        game_state.round_in_progress = true;
                        game_state.round += 1;
                        for (game_state.round_gsd) |*gsd_entry| {
                            gsd_entry.time_between_spawns_ms = 0;
                            gsd_entry.spawn_count = 0;
                        }
                    }
                } else if (game_state.round_in_progress) {
                    std.debug.assert(game_state.round > 0);
                    const rsd = round_spawn_data[(game_state.round - 1) % round_spawn_data.len];
                    var everything_was_spawned = true;
                    for (game_state.round_gsd) |gsd_entry, gsd_index| {
                        if (gsd_entry.spawn_count < rsd.group_spawn_data[gsd_index].spawn_count) {
                            everything_was_spawned = false;
                            break;
                        }
                    }
                    if (everything_was_spawned and game_state.alive_enemies.items.len == 0) { // End round
                        game_state.round_in_progress = false;
                        if (game_state.round >= round_spawn_data.len) { // Victory
                            game_mode = GameMode.game_end;
                        }
                    }
                }

                // Tower buy area -------------------------------------------------------------------------
                const tower_buy_item_dim = rl.Vector2{
                    .x = sprite_width * initial_scale_factor * tower_buy_area_sprite_scale,
                    .y = sprite_height * initial_scale_factor * tower_buy_area_sprite_scale,
                };
                const tower_buy_area_rows = @floatToInt(u32, @ceil(@intToFloat(f32, towers_data.len) / tower_buy_area_towers_per_row));
                const buy_area_rec = rl.Rectangle{
                    .x = screen_dim.x - tower_buy_item_dim.x * tower_buy_area_towers_per_row,
                    .y = 0,
                    .width = tower_buy_item_dim.x * tower_buy_area_towers_per_row,
                    .height = tower_buy_item_dim.y * @intToFloat(f32, tower_buy_area_rows),
                };

                tba_anim_timer += 1;
                if (tba_anim_timer >= @divTrunc(target_fps, anim_frames_speed)) {
                    tba_anim_timer = 0;
                    tba_anim_frame += 1;
                    if (tba_anim_frame > 3) tba_anim_frame = 0;
                }

                if ((game_state.tower_index_being_placed < 0) and
                    (rl.CheckCollisionPointRec(mouse_pos, buy_area_rec)) and
                    (rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT)) and
                    (!prev_frame_input.l_mouse_button_is_down))
                {
                    var selected_row: u32 = 0;
                    var selected_col: u32 = 0;
                    outer: while (selected_row < tower_buy_area_rows) : (selected_row += 1) {
                        selected_col = 0;
                        const towers_for_this_row = @min(tower_buy_area_towers_per_row, towers_data.len - selected_row * tower_buy_area_towers_per_row);
                        while (selected_col < towers_for_this_row) : (selected_col += 1) {
                            const tower_buy_item_rec = rl.Rectangle{
                                .x = buy_area_rec.x + @intToFloat(f32, selected_col) * tower_buy_item_dim.x,
                                .y = buy_area_rec.y + @intToFloat(f32, selected_row) * tower_buy_item_dim.y,
                                .width = tower_buy_item_dim.x,
                                .height = tower_buy_item_dim.y,
                            };

                            if (rl.CheckCollisionPointRec(mouse_pos, tower_buy_item_rec)) {
                                game_state.selected_tower = null;
                                game_state.tower_index_being_placed = @intCast(i32, selected_row * tower_buy_area_towers_per_row + selected_col);
                                break :outer;
                            }
                        }
                    }
                }

                // Misc updates -------------------------------------------------------------------------
                if (game_state.hp <= 0) game_mode = GameMode.game_end;

                var money_change_index: i32 = 0;
                while (money_change_index < game_state.money_change.items.len) : (money_change_index += 1) {
                    var money_change_entry = &game_state.money_change.items[@intCast(u32, money_change_index)];
                    money_change_entry.d_pos.y += 1;
                    if (money_change_entry.d_pos.y > 40) {
                        _ = game_state.money_change.orderedRemove(@intCast(u32, money_change_index));
                        money_change_index -= 1;
                    }
                }
                var hp_change_index: i32 = 0;
                while (hp_change_index < game_state.hp_change.items.len) : (hp_change_index += 1) {
                    var hp_change_entry = &game_state.hp_change.items[@intCast(u32, hp_change_index)];
                    hp_change_entry.d_pos.y += 1;
                    if (hp_change_entry.d_pos.y > 40) {
                        _ = game_state.hp_change.orderedRemove(@intCast(u32, hp_change_index));
                        hp_change_index -= 1;
                    }
                }

                prev_frame_input.l_mouse_button_is_down = rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT);
                prev_frame_screen_dim = screen_dim;
                last_time_ms = rl.GetTime() * 1000;

                // Render -------------------------------------------------------------------------
                rl.BeginDrawing();
                drawBackground(screen_dim, bg_offset);
                drawBoard(&board_map, &tileset, selected_tile_x, selected_tile_y, game_state.selected_tower, game_state.tower_index_being_placed);
                try drawSprites(&fba, &tileset, debug_hit_boxes, debug_projectile, &game_state.towers, &game_state.alive_enemies, &game_state.dead_enemies, &game_state.projectiles, selected_tile_x, selected_tile_y, game_state.tower_index_being_placed, tba_anim_frame);

                rl.DrawRectangleRec(buy_area_rec, color_off_white);
                var row_index: u32 = 0;
                while (row_index < tower_buy_area_rows) : (row_index += 1) {
                    var col_index: u32 = 0;
                    const towers_for_this_row = @min(tower_buy_area_towers_per_row, towers_data.len - row_index * tower_buy_area_towers_per_row);
                    while (col_index < towers_for_this_row) : (col_index += 1) {
                        const tower_data = towers_data[row_index * towers_for_this_row + col_index];
                        const ts_id = tower_data.tile_id + @enumToInt(Direction.down) * 4 + tba_anim_frame;
                        const target_tile_row = @divTrunc(ts_id, tileset.columns);
                        const target_tile_column = @mod(ts_id, tileset.columns);
                        const source_rect = rl.Rectangle{
                            .x = @intToFloat(f32, target_tile_column * sprite_width),
                            .y = @intToFloat(f32, target_tile_row * sprite_height),
                            .width = sprite_width,
                            .height = sprite_height,
                        };
                        const tower_buy_item_rec = rl.Rectangle{
                            .x = buy_area_rec.x + @intToFloat(f32, col_index) * tower_buy_item_dim.x,
                            .y = buy_area_rec.y + @intToFloat(f32, row_index) * tower_buy_item_dim.y,
                            .width = tower_buy_item_dim.x,
                            .height = tower_buy_item_dim.y,
                        };
                        const tint = if (@intCast(i32, tower_data.cost) > game_state.money) rl.GRAY else rl.WHITE;
                        rl.DrawTexturePro(tileset.tex, source_rect, tower_buy_item_rec, .{ .x = 0, .y = 0 }, 0, tint);
                        rl.DrawRectangleLinesEx(tower_buy_item_rec, 2, color_off_black);

                        if (rl.CheckCollisionPointRec(mouse_pos, tower_buy_item_rec)) {
                            var strz_buffer: [256]u8 = undefined;
                            const moused_over_tower_index = row_index * tower_buy_area_towers_per_row + col_index;

                            const name_strz = try std.fmt.bufPrintZ(&strz_buffer, "Name -- {s}", .{tower_names[moused_over_tower_index]});
                            const desc_strz_start = name_strz.len + 1;
                            const desc_strz = try std.fmt.bufPrintZ(strz_buffer[desc_strz_start..], "Desc -- {s}", .{tower_descs[moused_over_tower_index]});
                            const cost_strz_start = desc_strz_start + desc_strz.len + 1;
                            const cost_strz = try std.fmt.bufPrintZ(strz_buffer[cost_strz_start..], "Cost -- ${d}", .{towers_data[moused_over_tower_index].cost});

                            const cost_strz_dim = rl.MeasureTextEx(font, @ptrCast([*c]const u8, cost_strz), default_font_size, font_spacing);
                            const name_strz_dim = rl.MeasureTextEx(font, @ptrCast([*c]const u8, name_strz), default_font_size, font_spacing);
                            const desc_strz_dim = rl.MeasureTextEx(font, @ptrCast([*c]const u8, desc_strz), default_font_size, font_spacing);

                            const dest_rec_width = @max(@max(name_strz_dim.x, desc_strz_dim.x), cost_strz_dim.x);

                            const dest_rec = rl.Rectangle{
                                .x = tower_buy_item_rec.x - dest_rec_width,
                                .y = tower_buy_item_rec.y,
                                .width = dest_rec_width,
                                .height = name_strz_dim.y + desc_strz_dim.y + cost_strz_dim.y,
                            };
                            rl.DrawRectangleRec(dest_rec, color_off_white);
                            rl.DrawTextEx(font, @ptrCast([*c]const u8, cost_strz), rl.Vector2{ .x = dest_rec.x, .y = dest_rec.y }, default_font_size, font_spacing, color_off_black);
                            rl.DrawTextEx(font, @ptrCast([*c]const u8, name_strz), rl.Vector2{ .x = dest_rec.x, .y = dest_rec.y + cost_strz_dim.y }, default_font_size, font_spacing, color_off_black);
                            rl.DrawTextEx(font, @ptrCast([*c]const u8, desc_strz), rl.Vector2{ .x = dest_rec.x, .y = dest_rec.y + cost_strz_dim.y + name_strz_dim.y }, default_font_size, font_spacing, color_off_black);
                        }
                    }
                }

                const round_start_button_tint = if (game_state.round_in_progress) rl.GRAY else rl.WHITE;
                drawTile(&tileset, tileset.tile_name_to_id.get(hashString("play_button")).?, rl.Vector2{ .x = round_start_rec.x, .y = round_start_rec.y }, initial_scale_factor, round_start_button_tint);
                try drawStatusBar(&font, &tileset, game_state.money, game_state.hp, game_state.round, &game_state.money_change, &game_state.hp_change);
                if (debug_text_info)
                    try drawDebugTextInfo(&font, &game_state, selected_tile_pos, screen_dim);
                if (debug_origin)
                    drawDebugOrigin(screen_mid);
                rl.EndDrawing();
            },
        }
    }

    rl.CloseWindow();
}
