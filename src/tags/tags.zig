//! Mango-style tags: a 32-bit mask of visible tags per output, with
//! independent layout state for every tag. Tags are not workspaces: several
//! tags can be visible at once and windows can belong to several tags.

const std = @import("std");
const layout = @import("../layout/layout.zig");

pub const MAX_TAGS: u32 = 32;
pub const all_tags: u32 = 0xffff_ffff;

pub const TagState = struct {
    layout: layout.Kind = .tile,
    master_count: u16 = 1,
    master_factor: f32 = 0.55,
    gap: i32 = 6,
    inner_gap: i32 = 6,
    scroller_proportion: f32 = 0.9,
    scroller_offset: i32 = 0,
};

pub const Manager = struct {
    active: u32 = 1,
    previous: u32 = 1,
    states: [MAX_TAGS]TagState = [_]TagState{.{}} ** MAX_TAGS,
    history: [MAX_TAGS]u32 = [_]u32{0} ** MAX_TAGS,
    history_len: usize = 0,

    pub fn initDefault(default_layout: layout.Kind, master_count: u16, master_factor: f32, gap: i32) Manager {
        var m = Manager{};
        for (&m.states) |*s| {
            s.layout = default_layout;
            s.master_count = master_count;
            s.master_factor = master_factor;
            s.gap = gap;
            s.inner_gap = gap;
        }
        return m;
    }

    pub fn maskOf(tag_index: u32) u32 {
        return @as(u32, 1) << @intCast(tag_index % MAX_TAGS);
    }

    pub fn isVisible(self: *const Manager, window_tags: u32) bool {
        return (self.active & window_tags) != 0;
    }

    pub fn view(self: *Manager, tag_index: u32) void {
        self.pushHistory();
        self.previous = self.active;
        self.active = maskOf(tag_index);
    }

    pub fn toggle(self: *Manager, tag_index: u32) void {
        self.pushHistory();
        self.previous = self.active;
        self.active ^= maskOf(tag_index);
        if (self.active == 0) self.active = self.previous;
    }

    pub fn viewMask(self: *Manager, mask: u32) void {
        if (mask == 0) return;
        self.pushHistory();
        self.previous = self.active;
        self.active = mask;
    }

    pub fn viewPrevious(self: *Manager) void {
        const tmp = self.active;
        self.active = self.previous;
        self.previous = tmp;
    }

    pub fn viewLast(self: *Manager) void {
        if (self.history_len == 0) return;
        self.history_len -= 1;
        const mask = self.history[self.history_len];
        if (mask != 0) {
            self.previous = self.active;
            self.active = mask;
        }
    }

    fn pushHistory(self: *Manager) void {
        if (self.history_len < self.history.len) {
            self.history[self.history_len] = self.active;
            self.history_len += 1;
        }
    }

    pub fn state(self: *Manager, tag_index: u32) *TagState {
        return &self.states[tag_index % MAX_TAGS];
    }

    pub fn activeState(self: *Manager) *TagState {
        var idx: u5 = 0;
        while (idx < MAX_TAGS) : (idx += 1) {
            if ((self.active & (@as(u32, 1) << idx)) != 0) return &self.states[idx];
        }
        return &self.states[0];
    }

    pub fn cycleLayout(self: *Manager, forward: bool) void {
        const st = self.activeState();
        const kinds = layout.Kind.all();
        var idx: usize = 0;
        for (kinds, 0..) |k, i| {
            if (k == st.layout) {
                idx = i;
                break;
            }
        }
        idx = if (forward) (idx + 1) % kinds.len else (idx + kinds.len - 1) % kinds.len;
        st.layout = kinds[idx];
    }

    pub fn tagCount(mask: u32) u32 {
        return @popCount(mask);
    }
};

test "tag mask visibility" {
    var m = Manager.initDefault(.tile, 1, 0.55, 5);
    m.view(0);
    try std.testing.expect(m.isVisible(Manager.maskOf(0)));
    try std.testing.expect(!m.isVisible(Manager.maskOf(1)));
    m.toggle(2);
    try std.testing.expect(m.isVisible(Manager.maskOf(2)));
    try std.testing.expect(m.isVisible(Manager.maskOf(0)));
    m.toggle(0);
    try std.testing.expect(m.isVisible(Manager.maskOf(2)));
    try std.testing.expect(!m.isVisible(Manager.maskOf(0)));
}

test "tag history and previous" {
    var m = Manager.initDefault(.tile, 1, 0.55, 5);
    m.view(2);
    try std.testing.expectEqual(@as(u32, 4), m.active);
    m.view(3);
    try std.testing.expectEqual(@as(u32, 8), m.active);
    m.viewLast();
    try std.testing.expectEqual(@as(u32, 4), m.active);
    m.viewLast();
    try std.testing.expectEqual(@as(u32, 1), m.active);
}

test "independent tag layout state" {
    var m = Manager.initDefault(.tile, 1, 0.55, 5);
    m.view(0);
    m.activeState().layout = .grid;
    m.activeState().master_count = 3;
    m.view(1);
    try std.testing.expectEqual(layout.Kind.tile, m.activeState().layout);
    m.view(0);
    try std.testing.expectEqual(layout.Kind.grid, m.activeState().layout);
    try std.testing.expectEqual(@as(u16, 3), m.activeState().master_count);
}

test "cycle layout wraps" {
    var m = Manager.initDefault(.tile, 1, 0.55, 5);
    m.cycleLayout(true);
    try std.testing.expectEqual(layout.Kind.scroller, m.activeState().layout);
    m.cycleLayout(false);
    try std.testing.expectEqual(layout.Kind.tile, m.activeState().layout);
}
