const std = @import("std");
const config_mod = @import("config.zig");
const state_mod = @import("state.zig");
const network_mod = @import("protocol.zig");

const max_request_bytes: usize = 16 * 1024;

pub fn serverMain(shared: *state_mod.SharedState) !void {
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    defer std.posix.close(sock);

    try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&@as(c_int, 1)));
    const address = try std.net.Address.parseIp(config_mod.ui_bind_host, config_mod.ui_port);
    try std.posix.bind(sock, &address.any, address.getOsSockLen());
    try std.posix.listen(sock, 16);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = sock,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    while (!shared.shouldStop()) {
        _ = std.posix.poll(&poll_fds, 250) catch continue;
        if ((poll_fds[0].revents & std.posix.POLL.IN) == 0) continue;

        var client_addr: std.posix.sockaddr = undefined;
        var client_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        const client = std.posix.accept(sock, &client_addr, &client_len, 0) catch continue;
        defer std.posix.close(client);

        handleClient(shared, client) catch |err| {
            sendPlain(client, 500, "internal error") catch {};
            std.log.warn("http ui client failed: {s}", .{@errorName(err)});
        };
    }
}

fn handleClient(shared: *state_mod.SharedState, client: std.posix.socket_t) !void {
    var buffer: [max_request_bytes]u8 = undefined;
    var received: usize = 0;
    var headers_end: ?usize = null;
    var content_length: usize = 0;

    while (received < buffer.len) {
        const bytes_read = try std.posix.read(client, buffer[received..]);
        if (bytes_read == 0) break;
        received += bytes_read;

        if (headers_end == null) {
            headers_end = std.mem.indexOf(u8, buffer[0..received], "\r\n\r\n");
            if (headers_end) |index| {
                const headers = buffer[0..index];
                content_length = parseContentLength(headers) orelse 0;
                if (received >= index + 4 + content_length) break;
            }
        } else if (received >= headers_end.? + 4 + content_length) {
            break;
        }
    }

    const request = buffer[0..received];
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return error.BadRequest;
    const request_line = request[0..line_end];
    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const path = parts.next() orelse return error.BadRequest;
    const body = if (headers_end) |index| request[index + 4 .. @min(received, index + 4 + content_length)] else "";

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/")) {
        try sendDashboard(shared, client);
        return;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/healthz")) {
        try sendHealth(shared, client);
        return;
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/config")) {
        var next_config = shared.snapshot().config;
        try applyFormBody(&next_config, body);
        try shared.replaceConfigAndPersist(next_config);
        try sendRedirect(client, "/");
        return;
    }

    try sendPlain(client, 404, "not found");
}

fn sendDashboard(shared: *state_mod.SharedState, client: std.posix.socket_t) !void {
    const snapshot = shared.snapshot();
    var arena = std.heap.ArenaAllocator.init(shared.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var html = std.ArrayList(u8).empty;
    defer html.deinit(allocator);
    const writer = html.writer(allocator);

    try writer.print(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>WireNode</title>
        \\  <style>
        \\    :root {{ color-scheme: light; --bg: #f2efe8; --card: #fffaf1; --ink: #201915; --muted: #6b5b51; --line: #dfd1c2; --accent: #a44d2f; --accent-2: #d7874c; }}
        \\    * {{ box-sizing: border-box; }}
        \\    body {{ margin: 0; font-family: Georgia, "Iowan Old Style", serif; color: var(--ink); background: radial-gradient(circle at top left, #fff6db, transparent 32%), linear-gradient(135deg, #efe8db 0%, #f8f2e9 55%, #eadfce 100%); min-height: 100vh; }}
        \\    main {{ max-width: 860px; margin: 0 auto; padding: 32px 20px 48px; }}
        \\    .hero {{ padding: 20px 24px; border: 1px solid var(--line); background: rgba(255,250,241,0.86); backdrop-filter: blur(8px); box-shadow: 0 20px 45px rgba(70,42,24,0.08); }}
        \\    h1 {{ margin: 0 0 6px; font-size: clamp(2rem, 6vw, 3.4rem); letter-spacing: -0.04em; }}
        \\    p {{ margin: 0; line-height: 1.5; }}
        \\    .grid {{ display: grid; gap: 18px; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); margin-top: 22px; }}
        \\    .card {{ border: 1px solid var(--line); background: var(--card); padding: 18px; box-shadow: 0 10px 24px rgba(70,42,24,0.05); }}
        \\    .status {{ display: inline-block; padding: 6px 10px; border-radius: 999px; border: 1px solid var(--line); font-size: 0.9rem; color: var(--muted); margin-top: 12px; }}
        \\    label {{ display: block; font-size: 0.9rem; margin: 14px 0 6px; color: var(--muted); }}
        \\    input, select {{ width: 100%; border: 1px solid var(--line); background: #fffdf8; padding: 11px 12px; font: inherit; color: var(--ink); }}
        \\    .row {{ display: grid; gap: 12px; grid-template-columns: 1fr 120px; }}
        \\    .check {{ display: flex; align-items: center; gap: 10px; margin-top: 16px; font-size: 0.95rem; }}
        \\    .check input {{ width: auto; }}
        \\    button {{ border: 0; background: linear-gradient(135deg, var(--accent), var(--accent-2)); color: white; font: inherit; padding: 12px 18px; margin-top: 18px; cursor: pointer; }}
        \\    code {{ background: rgba(164,77,47,0.08); padding: 2px 6px; }}
        \\    .warn {{ margin-top: 16px; padding: 12px; border-left: 4px solid var(--accent); background: rgba(164,77,47,0.08); color: #5c2413; }}
        \\    @media (max-width: 640px) {{ .row {{ grid-template-columns: 1fr; }} main {{ padding-inline: 14px; }} }}
        \\  </style>
        \\</head>
        \\<body>
        \\  <main>
        \\    <section class="hero">
        \\      <h1>WireNode</h1>
        \\      <p>Servicio local para empujar audio remoto hacia WireDeck.</p>
        \\      <div class="status">estado: {s}</div>
        \\    </section>
        \\    <div class="grid">
        \\      <section class="card">
        \\        <h2>Destino</h2>
        \\        <p>El daemon escucha esta UI en <code>http://{s}:{d}</code> y guarda la configuración en <code>{s}</code>.</p>
        \\        <form method="post" action="/config">
        \\          <label for="host">Host WireDeck</label>
        \\          <input id="host" name="host" value="{s}" required>
        \\          <div class="row">
        \\            <div>
        \\              <label for="port">Puerto</label>
        \\              <input id="port" name="port" value="{d}" inputmode="numeric" required>
        \\            </div>
        \\            <div>
        \\              <label for="capture_mode">Captura</label>
        \\              <select id="capture_mode" name="capture_mode">
        \\                <option value="system-default" {s}>system-default</option>
        \\                <option value="tone" {s}>tone</option>
        \\                <option value="silence" {s}>silence</option>
        \\                <option value="stdin-f32le" {s}>stdin-f32le</option>
        \\              </select>
        \\            </div>
        \\          </div>
        \\          <label for="client_id">Client ID estable</label>
        \\          <input id="client_id" name="client_id" value="{s}" required>
        \\          <label for="client_name">Nombre visible</label>
        \\          <input id="client_name" name="client_name" value="{s}" required>
        \\          <label for="stream_name">Nombre del stream</label>
        \\          <input id="stream_name" name="stream_name" value="{s}" required>
        \\          <div class="check">
        \\            <input id="enabled" type="checkbox" name="enabled" value="1" {s}>
        \\            <label for="enabled">Activar envío en segundo plano</label>
        \\          </div>
        \\          <button type="submit">Guardar</button>
        \\        </form>
        \\      </section>
        \\      <section class="card">
        \\        <h2>Estado actual</h2>
        \\        <p>endpoint: <code>{s}</code></p>
        \\        <p>último paquete: <code>{d}</code></p>
        \\        <p>error: <code>{s}</code></p>
        \\        <div class="warn">La vía de transporte y la persistencia ya están implementadas. La captura real de audio del sistema en macOS requiere un backend Core Audio Tap con autorización del usuario; eso no puede resolverse limpiamente como daemon puro antes del primer login.</div>
        \\      </section>
        \\    </div>
        \\  </main>
        \\</body>
        \\</html>
    , .{
        @tagName(snapshot.status.sender_state),
        config_mod.ui_bind_host,
        config_mod.ui_port,
        shared.config_path,
        snapshot.config.host.slice(),
        snapshot.config.port,
        selectedAttr(snapshot.config.capture_mode == .system_default),
        selectedAttr(snapshot.config.capture_mode == .tone),
        selectedAttr(snapshot.config.capture_mode == .silence),
        selectedAttr(snapshot.config.capture_mode == .stdin_f32le),
        snapshot.config.client_id.slice(),
        snapshot.config.client_name.slice(),
        snapshot.config.stream_name.slice(),
        checkedAttr(snapshot.config.enabled),
        snapshot.status.endpoint.slice(),
        snapshot.status.last_packet_ns,
        snapshot.status.last_error.slice(),
    });

    try sendHtml(client, html.items);
}

fn sendHealth(shared: *state_mod.SharedState, client: std.posix.socket_t) !void {
    const snapshot = shared.snapshot();
    var buffer: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buffer, "{{\"state\":\"{s}\",\"endpoint\":\"{s}\"}}", .{
        @tagName(snapshot.status.sender_state),
        snapshot.status.endpoint.slice(),
    });
    try sendResponse(client, 200, "application/json", body);
}

fn applyFormBody(config: *config_mod.Config, body: []const u8) !void {
    var enabled = false;
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, entry, '=') orelse entry.len;
        const key = try urlDecode(entry[0..eq_index]);
        defer std.heap.page_allocator.free(key);
        const value = if (eq_index < entry.len) try urlDecode(entry[eq_index + 1 ..]) else try std.heap.page_allocator.dupe(u8, "");
        defer std.heap.page_allocator.free(value);

        if (std.mem.eql(u8, key, "enabled")) {
            enabled = true;
        } else if (std.mem.eql(u8, key, "host")) {
            try config.host.set(value);
        } else if (std.mem.eql(u8, key, "port")) {
            config.port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, key, "client_id")) {
            try config.client_id.set(value);
        } else if (std.mem.eql(u8, key, "client_name")) {
            try config.client_name.set(value);
        } else if (std.mem.eql(u8, key, "stream_name")) {
            try config.stream_name.set(value);
        } else if (std.mem.eql(u8, key, "capture_mode")) {
            config.capture_mode = parseCaptureMode(value) orelse return error.UnknownCaptureMode;
        }
    }
    config.enabled = enabled;
}

fn parseContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (startsWithIgnoreCase(line, "Content-Length:")) {
            const raw_value = std.mem.trim(u8, line["Content-Length:".len..], &std.ascii.whitespace);
            return std.fmt.parseInt(usize, raw_value, 10) catch null;
        }
    }
    return null;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn urlDecode(value: []const u8) ![]u8 {
    var out = try std.heap.page_allocator.alloc(u8, value.len);
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < value.len) : (read_index += 1) {
        switch (value[read_index]) {
            '+' => {
                out[write_index] = ' ';
                write_index += 1;
            },
            '%' => {
                if (read_index + 2 >= value.len) return error.BadPercentEncoding;
                out[write_index] = try decodeHexByte(value[read_index + 1], value[read_index + 2]);
                write_index += 1;
                read_index += 2;
            },
            else => {
                out[write_index] = value[read_index];
                write_index += 1;
            },
        }
    }
    return std.heap.page_allocator.realloc(out, write_index);
}

fn decodeHexByte(a: u8, b: u8) !u8 {
    return (try decodeHexNibble(a) << 4) | try decodeHexNibble(b);
}

fn decodeHexNibble(value: u8) !u8 {
    if (value >= '0' and value <= '9') return value - '0';
    if (value >= 'a' and value <= 'f') return value - 'a' + 10;
    if (value >= 'A' and value <= 'F') return value - 'A' + 10;
    return error.BadPercentEncoding;
}

fn parseCaptureMode(value: []const u8) ?network_mod.CaptureMode {
    if (std.mem.eql(u8, value, "tone")) return .tone;
    if (std.mem.eql(u8, value, "silence")) return .silence;
    if (std.mem.eql(u8, value, "stdin-f32le")) return .stdin_f32le;
    if (std.mem.eql(u8, value, "system-default")) return .system_default;
    return null;
}

fn sendHtml(client: std.posix.socket_t, body: []const u8) !void {
    try sendResponse(client, 200, "text/html; charset=utf-8", body);
}

fn sendPlain(client: std.posix.socket_t, status: u16, body: []const u8) !void {
    try sendResponse(client, status, "text/plain; charset=utf-8", body);
}

fn sendRedirect(client: std.posix.socket_t, location: []const u8) !void {
    var header: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(&header,
        "HTTP/1.1 303 See Other\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{location},
    );
    _ = try std.posix.write(client, response);
}

fn sendResponse(client: std.posix.socket_t, status: u16, content_type: []const u8, body: []const u8) !void {
    var header: [512]u8 = undefined;
    const reason = switch (status) {
        200 => "OK",
        303 => "See Other",
        404 => "Not Found",
        else => "Internal Server Error",
    };
    const response = try std.fmt.bufPrint(&header,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n",
        .{ status, reason, content_type, body.len },
    );
    _ = try std.posix.write(client, response);
    if (body.len > 0) _ = try std.posix.write(client, body);
}

fn selectedAttr(enabled: bool) []const u8 {
    return if (enabled) "selected" else "";
}

fn checkedAttr(enabled: bool) []const u8 {
    return if (enabled) "checked" else "";
}
