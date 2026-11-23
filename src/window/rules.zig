//! Window rule matching. Patterns support shell-style `*` and `?` wildcards so
//! users do not need to write regular expressions.

const std = @import("std");
const config = @import("../config/config.zig");

pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var match: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or std.ascii.toLower(pattern[p]) == std.ascii.toLower(text[t]))) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            match = t;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            match += 1;
            t = match;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

pub fn matches(rule: *const config.Rule, app_id: []const u8, title: []const u8) bool {
    if (rule.app_id.len > 0 and !globMatch(rule.app_id, app_id)) return false;
    if (rule.title.len > 0 and !globMatch(rule.title, title)) return false;
    return true;
}

pub fn findFor(cfg: *const config.Config, app_id: []const u8, title: []const u8) ?*const config.Rule {
    var found: ?*const config.Rule = null;
    for (cfg.rules[0..cfg.rule_count]) |*r| {
        if (matches(r, app_id, title)) found = r;
    }
    return found;
}

test "glob matching" {
    try std.testing.expect(globMatch("fire*", "firefox"));
    try std.testing.expect(globMatch("*term*", "AlacrittyTerminal"));
    try std.testing.expect(globMatch("a?c", "abc"));
    try std.testing.expect(!globMatch("a?c", "ac"));
    try std.testing.expect(globMatch("", ""));
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(!globMatch("firefox", "fire"));
}

test "rule matching requires all specified fields" {
    const rule = config.Rule{ .app_id = "foot*", .title = "*shell*", .floating = true };
    try std.testing.expect(matches(&rule, "foot", "shell"));
    try std.testing.expect(!matches(&rule, "foot", "editor"));
    try std.testing.expect(!matches(&rule, "alacritty", "shell"));
}
