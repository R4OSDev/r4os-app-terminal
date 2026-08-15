const r4os = @import("r4os");
const r4std = @import("r4std");

const INPUT_MAX: usize = 128;
const HISTORY_DEPTH: usize = 16;
const PATH_MAX: usize = 128;
const FILE_CHUNK_MAX: usize = 1024;
const VERSION_FILE_MAX: usize = 256;
const INVENTORY_FILE_MAX: usize = 2048;
const DIR_ENTRY_MAX: usize = 128;
const AUTOEXEC_FILE_MAX: usize = 4096;
const ENV_VALUE_MAX: usize = r4os.abi.environment_value_max;
const SORT_LINE_MAX: usize = 64;
const PROGRAM_EXT = ".R4X";
const BATCH_EXT = ".BAT";
const autoexec_path = "/AUTOEXEC.BAT";
const version_unknown = "unknown";
const default_path = "C:\\R4OS\\SOFTWARE\\TERMINAL;C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG";
const default_prompt = "$P$G";
const default_shell = "C:\\R4OS\\SOFTWARE\\TERMINAL\\TERMINAL.R4X";
const default_cwd = "C:\\";
const default_temp = "C:\\TEMP";
const environment_registry_key = "SYSTEM\\Environment";
const path_registry_value = "PATH";

const KEY_UP: u8 = 0x80;
const KEY_DOWN: u8 = 0x81;
const KEY_F3: u8 = 0x82;

const Mode = enum {
    primary,
    primary_no_autoexec,
    help,
    selftest,
    builtintest,
    launchtest,
    batchtest,
};

const BuiltinResult = enum {
    not_handled,
    ok,
    failed,
};

const PersistentPathStatus = enum {
    ok,
    missing,
    too_long,
    bad_type,
    registry_error,
};

const PersistentPathRead = struct {
    status: PersistentPathStatus,
    len: usize = 0,
    result: i32 = 0,
};

const TerminalState = struct {
    sys: r4os.r4sys.Context,
    dev: r4os.r4dev.Context,
    history: [HISTORY_DEPTH][INPUT_MAX]u8 = .{.{0} ** INPUT_MAX} ** HISTORY_DEPTH,
    history_lens: [HISTORY_DEPTH]usize = .{0} ** HISTORY_DEPTH,
    history_count: usize = 0,
    history_next: usize = 0,
    echo_on: bool = true,
    verify_on: bool = false,
    errorlevel: i32 = 0,
    path_env: [ENV_VALUE_MAX]u8 = .{0} ** ENV_VALUE_MAX,
    path_len: usize = 0,
    prompt_env: [ENV_VALUE_MAX]u8 = .{0} ** ENV_VALUE_MAX,
    prompt_len: usize = 0,
    shell_env: [ENV_VALUE_MAX]u8 = .{0} ** ENV_VALUE_MAX,
    shell_len: usize = 0,
    cwd_env: [ENV_VALUE_MAX]u8 = .{0} ** ENV_VALUE_MAX,
    cwd_len: usize = 0,
    temp_env: [ENV_VALUE_MAX]u8 = .{0} ** ENV_VALUE_MAX,
    temp_len: usize = 0,
    blaster_env: [ENV_VALUE_MAX]u8 = .{0} ** ENV_VALUE_MAX,
    blaster_len: usize = 0,
    redirect_active: bool = false,
    redirect_append: bool = false,
    redirect_started: bool = false,
    redirect_error: bool = false,
    exit_requested: bool = false,
    redirect_path: [PATH_MAX:0]u8 = .{0} ** PATH_MAX,

    fn run(self: *TerminalState, run_autoexec: bool) i32 {
        self.initializeSession();
        if (run_autoexec) self.runAutoexec();
        self.printPrompt();

        var input: [INPUT_MAX]u8 = undefined;
        var len: usize = 0;
        var history_age: ?usize = null;

        while (true) {
            const c = self.sys.readKey();
            switch (c) {
                0 => self.sys.taskYield(),
                '\n' => {
                    self.write("\r\n");
                    self.addHistory(input[0..len]);
                    self.executeLine(input[0..len]);
                    if (self.exit_requested) return self.errorlevel;
                    len = 0;
                    history_age = null;
                    self.printPrompt();
                },
                0x08 => {
                    if (len > 0) {
                        len -= 1;
                        self.putc(0x08);
                        history_age = null;
                    }
                },
                0x03 => {
                    self.write("^C\r\n");
                    len = 0;
                    history_age = null;
                    self.printPrompt();
                },
                0x1B => {},
                KEY_UP => {
                    if (self.previousHistoryAge(history_age)) |age| {
                        history_age = age;
                        self.replaceInputFromHistory(age, input[0..], &len);
                    }
                },
                KEY_DOWN => {
                    if (self.nextHistoryAge(history_age)) |age| {
                        history_age = age;
                        self.replaceInputFromHistory(age, input[0..], &len);
                    } else if (history_age != null) {
                        history_age = null;
                        self.clearInputLine(len);
                        len = 0;
                    }
                },
                KEY_F3 => {
                    if (self.history_count != 0) {
                        history_age = 0;
                        self.replaceInputFromHistory(0, input[0..], &len);
                    }
                },
                else => {
                    if (c >= 0x20 and c <= 0x7E and len < input.len) {
                        const visible = upper(c);
                        input[len] = visible;
                        len += 1;
                        self.putc(visible);
                        history_age = null;
                    }
                },
            }
        }
    }

    fn initializeSession(self: *TerminalState) void {
        self.echo_on = true;
        self.errorlevel = 0;
        self.redirect_active = false;
        self.redirect_append = false;
        self.redirect_started = false;
        self.redirect_error = false;
        self.exit_requested = false;
        _ = self.setPath(default_path);
        self.loadStartupPersistentPath();
        _ = self.setPrompt(default_prompt);
        _ = self.setShell(default_shell);
        _ = self.setCwd(default_cwd);
        _ = self.setTemp(default_temp);
        _ = self.setBlaster("");
        self.syncProcessEnvironment();
    }

    fn write(self: *TerminalState, value: []const u8) void {
        if (self.redirect_active) {
            self.writeRedirect(value);
        } else {
            self.sys.write(value);
        }
    }

    fn println(self: *TerminalState, value: []const u8) void {
        self.write(value);
        self.write("\r\n");
    }

    fn putc(self: *TerminalState, ch: u8) void {
        var one = [_]u8{ch};
        self.write(one[0..]);
    }

    fn printI32(self: *TerminalState, value: i32) void {
        if (!self.redirect_active) {
            self.sys.printI32(value);
            return;
        }
        var buf: [16]u8 = undefined;
        self.write(formatI32(value, buf[0..]));
    }

    fn printU64(self: *TerminalState, value: u64) void {
        if (!self.redirect_active) {
            self.sys.printU64(value);
            return;
        }
        var buf: [24]u8 = undefined;
        self.write(formatU64(value, buf[0..]));
    }

    fn beginRedirect(self: *TerminalState, target: []const u8, append: bool) bool {
        self.redirect_active = false;
        self.redirect_append = append;
        self.redirect_started = false;
        self.redirect_error = false;
        @memset(self.redirect_path[0..], 0);
        if (!copyCommandZ(self.redirect_path[0..], target)) return false;
        self.redirect_active = true;
        return true;
    }

    fn endRedirect(self: *TerminalState) bool {
        const ok = !self.redirect_error;
        self.redirect_active = false;
        self.redirect_append = false;
        self.redirect_started = false;
        self.redirect_error = false;
        return ok;
    }

    fn writeRedirect(self: *TerminalState, value: []const u8) void {
        if (value.len == 0 or self.redirect_error) return;
        const written = if (!self.redirect_started and !self.redirect_append)
            self.sys.fileWrite(&self.redirect_path, value)
        else
            self.sys.fileAppend(&self.redirect_path, value);
        self.redirect_started = true;
        if (written != @as(i32, @intCast(value.len))) self.redirect_error = true;
    }

    fn runBatchContent(self: *TerminalState, raw: []const u8) void {
        const data = stripBom(raw);
        var start: usize = 0;
        while (start < data.len) {
            var end = start;
            while (end < data.len and data[end] != '\n' and data[end] != '\r') : (end += 1) {}
            const line = trim(data[start..end]);
            if (line.len != 0) {
                if (self.echo_on and line[0] != '@') {
                    self.write(line);
                    self.write("\r\n");
                }
                self.executeLine(line);
            }
            start = end;
            while (start < data.len and (data[start] == '\n' or data[start] == '\r')) : (start += 1) {}
        }
    }

    fn executeLine(self: *TerminalState, raw: []const u8) void {
        var cmd = trim(raw);
        if (cmd.len == 0) {
            self.setErrorlevel(0);
            return;
        }
        if (cmd[0] == '@') {
            cmd = trim(cmd[1..]);
            if (cmd.len == 0) {
                self.setErrorlevel(0);
                return;
            }
        }
        if (startsWith(cmd, "PATH=")) {
            _ = self.pathCommand(cmd["PATH=".len..]);
            return;
        }
        if (startsWith(cmd, "PROMPT=")) {
            _ = self.promptCommand(cmd["PROMPT=".len..]);
            return;
        }
        if (driveSwitchLetter(cmd)) |letter| {
            _ = self.changeDriveCommand(letter);
            return;
        }

        if (containsPipeSyntax(cmd)) {
            _ = self.fail("Pipes are not migrated yet");
            return;
        }

        if (containsRedirectionSyntax(cmd)) {
            _ = self.executeWithRedirection(cmd);
            return;
        }

        switch (self.executeUserlandBuiltin(cmd)) {
            .not_handled => {},
            .ok, .failed => return,
        }

        _ = self.executeExternalProgram(cmd);
    }

    fn executeUserlandBuiltin(self: *TerminalState, cmd: []const u8) BuiltinResult {
        const parsed = splitCommand(cmd);
        const name = parsed.name;
        const args = parsed.args;

        if (equalsIgnoreCase(name, "ECHO")) return self.echoCommand(args);
        if (equalsIgnoreCase(name, "REM")) {
            self.setErrorlevel(0);
            return .ok;
        }
        if (equalsIgnoreCase(name, "PATH")) return self.pathCommand(args);
        if (equalsIgnoreCase(name, "PROMPT")) return self.promptCommand(args);
        if (equalsIgnoreCase(name, "SET")) return self.setCommand(args);
        if (equalsIgnoreCase(name, "DESKTOP")) return self.desktopCommand(args);
        if (equalsIgnoreCase(name, "CD") or equalsIgnoreCase(name, "CHDIR")) return self.cdCommand(args);
        if (equalsIgnoreCase(name, "CLS")) return self.clsCommand(args);
        if (equalsIgnoreCase(name, "PAUSE")) return self.pauseCommand(args);
        if (equalsIgnoreCase(name, "SLEEP")) return self.sleepCommand(args);
        if (equalsIgnoreCase(name, "COLOR")) return self.colorCommand(args);
        if (equalsIgnoreCase(name, "DATE")) return self.dateCommand(args);
        if (equalsIgnoreCase(name, "TIME")) return self.timeCommand(args);
        if (equalsIgnoreCase(name, "VOL")) return self.volCommand(args);
        if (equalsIgnoreCase(name, "VERIFY")) return self.verifyCommand(args);
        if (equalsIgnoreCase(name, "MORE")) return self.moreCommand(args);
        if (equalsIgnoreCase(name, "SORT")) return self.sortCommand(args);
        if (equalsIgnoreCase(name, "EXIT")) return self.exitCommand(args);
        if (equalsIgnoreCase(name, "POWEROFF") or equalsIgnoreCase(name, "SHUTDOWN")) return self.poweroffCommand(args);
        if (equalsIgnoreCase(name, "REBOOT")) return self.rebootCommand(args);
        if (equalsIgnoreCase(name, "HALT")) return self.haltCommand(args);
        if (equalsIgnoreCase(name, "VER")) return self.verCommand(args);
        if (equalsIgnoreCase(name, "TYPE")) return self.typeCommand(args);
        if (equalsIgnoreCase(name, "DIR")) return self.dirCommand(args);
        if (equalsIgnoreCase(name, "COPY")) return self.copyCommand(args);
        if (equalsIgnoreCase(name, "DEL") or equalsIgnoreCase(name, "ERASE")) return self.deleteCommand(args);
        if (equalsIgnoreCase(name, "REN") or equalsIgnoreCase(name, "RENAME")) return self.renameCommand(args);
        if (equalsIgnoreCase(name, "MD") or equalsIgnoreCase(name, "MKDIR")) return self.makeDirCommand(args);
        if (equalsIgnoreCase(name, "RD") or equalsIgnoreCase(name, "RMDIR")) return self.removeDirCommand(args);
        if (equalsIgnoreCase(name, "GOTO") or equalsIgnoreCase(name, "CALL") or equalsIgnoreCase(name, "SHIFT") or equalsIgnoreCase(name, "IF") or equalsIgnoreCase(name, "FOR")) {
            return self.fail("Batch control flow is not migrated yet");
        }
        return .not_handled;
    }

    fn executeWithRedirection(self: *TerminalState, cmd: []const u8) BuiltinResult {
        const redir = parseRedirection(cmd) orelse return self.fail("Invalid redirection syntax");
        if (redir.mode == .stdin) return self.fail("Input redirection is not migrated yet");
        if (redir.command.len == 0 or redir.target.len == 0) return self.fail("Invalid redirection syntax");
        if (containsPipeSyntax(redir.command) or containsRedirectionSyntax(redir.target)) return self.fail("Complex redirection is not migrated yet");

        switch (self.executeUserlandBuiltinRedirected(redir.command, redir.target, redir.mode == .stdout_append)) {
            .not_handled => return self.fail("Redirection for external programs is not migrated yet"),
            .ok => return .ok,
            .failed => return .failed,
        }
    }

    fn executeUserlandBuiltinRedirected(self: *TerminalState, command: []const u8, target: []const u8, append: bool) BuiltinResult {
        if (!self.beginRedirect(target, append)) return self.fail("Redirection target invalid");
        const result = self.executeUserlandBuiltin(command);
        const redirect_ok = self.endRedirect();
        if (!redirect_ok) return self.fail("Redirection write failed");
        return result;
    }

    fn executeExternalProgram(self: *TerminalState, cmd: []const u8) BuiltinResult {
        const parsed = splitCommand(cmd);
        if (parsed.name.len == 0) {
            self.setErrorlevel(0);
            return .ok;
        }
        var batch_path_buf: [PATH_MAX]u8 = undefined;
        if (self.resolveBatchFile(parsed.name, batch_path_buf[0..])) |batch_path| {
            return self.runBatchFile(batch_path, parsed.args);
        }
        var path_buf: [PATH_MAX]u8 = undefined;
        const resolved = self.resolveExternalProgram(parsed.name, path_buf[0..]) orelse {
            self.write("Bad command or file name: ");
            self.write(parsed.name);
            self.write("\r\n");
            self.setErrorlevel(1);
            return .failed;
        };
        // NAME /? (0.61.14): Traegt das Zielmodul ein Helpfile im
        // R4M0-Container, zeigt das Terminal es an und startet das Programm
        // NICHT. Ohne Container-Helpfile wird /? unveraendert durchgereicht -
        // Programme mit eigener /?-Behandlung behalten ihr Verhalten.
        if (isHelpSwitch(trim(parsed.args))) {
            if (self.showContainerHelp(resolved.path)) {
                self.setErrorlevel(0);
                return .ok;
            }
        }
        const selftest_launch = hasSelftestSwitch(parsed.args);
        const console_mode_launch = selftest_launch or hasConsoleUtilitySwitch(parsed.args);
        if (resolved.class_id == 3 and !selftest_launch) {
            _ = self.fail("Service programs cannot be launched from Terminal yet");
            return .failed;
        }
        if (isDesktopShellProgram(resolved.path)) {
            if (trim(parsed.args).len != 0) {
                _ = self.fail("R4DESK.R4X is the desktop shell; use DESKTOP in Terminal Mode");
                return .failed;
            }
            return self.desktopCommand("");
        }
        var path_z: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        var args_z: [INPUT_MAX:0]u8 = .{0} ** INPUT_MAX;
        if (!copyCommandZ(path_z[0..], resolved.path) or !copyCommandZ(args_z[0..], parsed.args)) {
            _ = self.fail("Path or argument list too long");
            return .failed;
        }
        const launch_policy: r4os.abi.LaunchPolicy = if (console_mode_launch) .console else .auto;
        const resources = r4os.Resources{ .sys = self.sys };
        var process = switch (resources.spawn(.{ .ptr = @ptrCast(&path_z), .len = @intCast(resolved.path.len) }, &args_z, launch_policy)) {
            .process => |handle| handle,
            .failure => |raw| {
                self.reportLaunchFailure(resolved.path, raw);
                self.setErrorlevel(1);
                return .failed;
            },
        };
        const exit_code = switch (process.wait(r4os.time_contract.timeoutForever())) {
            .exited => |code| code,
            .failure => |raw| {
                self.reportLaunchFailure(resolved.path, raw);
                self.setErrorlevel(1);
                return .failed;
            },
            .would_block, .timed_out => {
                self.reportLaunchFailure(resolved.path, r4os.abi.io_error_timeout);
                self.setErrorlevel(1);
                return .failed;
            },
        };
        if (process.valid()) {
            self.reportLaunchFailure(resolved.path, r4os.abi.err_closed);
            self.setErrorlevel(1);
            return .failed;
        }
        self.setErrorlevel(exit_code);
        return if (self.errorlevel == 0) .ok else .failed;
    }

    fn resolveBatchFile(self: *TerminalState, name: []const u8, out: []u8) ?[]const u8 {
        if (name.len == 0) return null;
        if (hasProgramPathSyntax(name)) {
            if (self.tryBatchCandidate(name, out)) |path| return path;
            if (self.cwd_len != 0 and !isAbsoluteDosPath(name)) {
                if (self.tryBatchInDirectory(self.cwd_env[0..self.cwd_len], name, out)) |path| return path;
            }
            return null;
        }
        if (self.cwd_len != 0) {
            if (self.tryBatchInDirectory(self.cwd_env[0..self.cwd_len], name, out)) |path| return path;
        }
        var pos: usize = 0;
        const path = self.path_env[0..self.path_len];
        while (nextPathDirectory(path, &pos)) |dir| {
            if (dir.len == 0) continue;
            if (self.tryBatchInDirectory(dir, name, out)) |resolved| return resolved;
        }
        return null;
    }

    fn tryBatchInDirectory(self: *TerminalState, dir: []const u8, name: []const u8, out: []u8) ?[]const u8 {
        var joined: [PATH_MAX]u8 = undefined;
        const candidate = joinDosPath(dir, name, joined[0..]) orelse return null;
        return self.tryBatchCandidate(candidate, out);
    }

    fn tryBatchCandidate(self: *TerminalState, candidate: []const u8, out: []u8) ?[]const u8 {
        if (hasBatchExtension(candidate)) return self.batchCandidateExists(candidate, out);
        var with_ext: [PATH_MAX]u8 = undefined;
        const ext_candidate = appendBatchExtension(candidate, with_ext[0..]) orelse return null;
        if (self.batchCandidateExists(ext_candidate, out)) |path| return path;
        return null;
    }

    fn batchCandidateExists(self: *TerminalState, candidate: []const u8, out: []u8) ?[]const u8 {
        if (candidate.len == 0 or candidate.len >= out.len) return null;
        var path_z: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        if (!copyCommandZ(path_z[0..], candidate)) return null;
        if (!self.sys.exists(&path_z)) return null;
        @memcpy(out[0..candidate.len], candidate);
        return out[0..candidate.len];
    }

    fn runBatchFile(self: *TerminalState, path: []const u8, args: []const u8) BuiltinResult {
        _ = args;
        var path_z: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        if (!copyCommandZ(path_z[0..], path)) return self.fail("Batch path too long");
        var data: [AUTOEXEC_FILE_MAX]u8 = undefined;
        const read = self.sys.fileRead(&path_z, data[0..]);
        if (read <= 0) return self.fail("Batch file not readable");
        self.runBatchContent(data[0..@intCast(read)]);
        return if (self.errorlevel == 0) .ok else .failed;
    }

    fn resolveExternalProgram(self: *TerminalState, name: []const u8, out: []u8) ?ResolvedProgram {
        if (name.len == 0) return null;
        if (hasProgramPathSyntax(name)) {
            if (self.tryProgramCandidate(name, out)) |resolved| return resolved;
            if (self.cwd_len != 0 and !isAbsoluteDosPath(name)) {
                if (self.tryProgramInDirectory(self.cwd_env[0..self.cwd_len], name, out)) |resolved| return resolved;
            }
            return null;
        }

        if (self.cwd_len != 0) {
            if (self.tryProgramInDirectory(self.cwd_env[0..self.cwd_len], name, out)) |resolved| return resolved;
        }

        var pos: usize = 0;
        const path = self.path_env[0..self.path_len];
        while (nextPathDirectory(path, &pos)) |dir| {
            if (dir.len == 0) continue;
            if (self.tryProgramInDirectory(dir, name, out)) |resolved| return resolved;
        }
        return null;
    }

    fn tryProgramInDirectory(self: *TerminalState, dir: []const u8, name: []const u8, out: []u8) ?ResolvedProgram {
        var joined: [PATH_MAX]u8 = undefined;
        const candidate = joinDosPath(dir, name, joined[0..]) orelse return null;
        return self.tryProgramCandidate(candidate, out);
    }

    fn tryProgramCandidate(self: *TerminalState, candidate: []const u8, out: []u8) ?ResolvedProgram {
        if (self.classifyProgramCandidate(candidate, out)) |resolved| return resolved;
        if (!hasR4XExtension(candidate)) {
            var with_ext: [PATH_MAX]u8 = undefined;
            const ext_candidate = appendProgramExtension(candidate, with_ext[0..]) orelse return null;
            if (self.classifyProgramCandidate(ext_candidate, out)) |resolved| return resolved;
        }
        return null;
    }

    fn classifyProgramCandidate(self: *TerminalState, candidate: []const u8, out: []u8) ?ResolvedProgram {
        if (candidate.len == 0 or candidate.len >= out.len) return null;
        var path_z: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        if (!copyCommandZ(path_z[0..], candidate)) return null;
        const class_id = self.sys.base.programClass(&path_z, .auto);
        if (class_id <= 0) return null;
        @memcpy(out[0..candidate.len], candidate);
        return .{ .path = out[0..candidate.len], .class_id = class_id };
    }

    fn reportLaunchFailure(self: *TerminalState, path: []const u8, rc: i32) void {
        self.write("Program launch failed: ");
        self.write(path);
        self.write(" (");
        self.printI32(rc);
        self.write(")\r\n");
    }

    fn poweroffCommand(self: *TerminalState, args: []const u8) BuiltinResult {
        if (trim(args).len != 0) return self.fail("Usage: POWEROFF");
        self.println("System poweroff.");
        self.sys.systemPoweroff();
    }

    fn rebootCommand(self: *TerminalState, args: []const u8) BuiltinResult {
        if (trim(args).len != 0) return self.fail("Usage: REBOOT");
        self.println("System reboot.");
        self.sys.systemReboot();
    }

    fn haltCommand(self: *TerminalState, args: []const u8) BuiltinResult {
        if (trim(args).len != 0) return self.fail("Usage: HALT");
        self.println("System halt.");
        self.sys.systemHalt();
    }

    fn echoCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len == 0) {
            self.write("ECHO is ");
            self.println(if (self.echo_on) "on" else "off");
            self.setErrorlevel(0);
            return .ok;
        }
        if (equalsIgnoreCase(arg, "ON")) {
            self.echo_on = true;
            self.setErrorlevel(0);
            return .ok;
        }
        if (equalsIgnoreCase(arg, "OFF")) {
            self.echo_on = false;
            self.setErrorlevel(0);
            return .ok;
        }
        self.write(if (arg[0] == '.') arg[1..] else arg);
        self.write("\r\n");
        self.setErrorlevel(0);
        return .ok;
    }

    fn verCommand(self: *TerminalState, arg: []const u8) BuiltinResult {
        if (trim(arg).len != 0) return .not_handled;
        var version_data: [VERSION_FILE_MAX]u8 = undefined;
        self.write("R4OS Release ");
        self.println(self.releaseVersion(version_data[0..]));

        const active = self.dev.kernelVersion();
        var active_text_buffer: [32]u8 = undefined;
        self.write("Kernel active ");
        self.println(if (active) |value| r4os.version_info.formatKernelVersion(value, active_text_buffer[0..]) orelse version_unknown else version_unknown);

        var inventory_data: [INVENTORY_FILE_MAX]u8 = undefined;
        const inventory_read = self.sys.fileReadAt(r4os.version_info.inventory_file_path, 0, inventory_data[0..]);
        const installed = if (inventory_read > 0)
            r4os.version_info.parseInstalledKernelVersion(inventory_data[0..@intCast(inventory_read)])
        else
            null;
        self.write("Kernel installed ");
        self.write(installed orelse version_unknown);
        if (active) |value| {
            if (installed) |installed_text| {
                if (r4os.version_info.restartRequired(value, installed_text)) self.write(" (Restart required)");
            }
        }
        self.println("");
        self.setErrorlevel(0);
        return .ok;
    }

    fn releaseVersion(self: *TerminalState, scratch: []u8) []const u8 {
        const read = self.sys.fileRead(r4os.version_info.release_file_path, scratch);
        if (read <= 0) return version_unknown;
        const len: usize = @intCast(read);
        return r4os.version_info.parseReleaseVersion(scratch[0..len]) orelse version_unknown;
    }

    fn runAutoexec(self: *TerminalState) void {
        var data: [AUTOEXEC_FILE_MAX]u8 = undefined;
        const read = self.sys.fileRead(autoexec_path, data[0..]);
        if (read <= 0) return;
        const len: usize = @intCast(read);
        self.executeScript(stripBom(data[0..len]));
    }

    fn executeScript(self: *TerminalState, data: []const u8) void {
        var start: usize = 0;
        while (start < data.len) {
            var end = start;
            while (end < data.len and data[end] != '\n' and data[end] != '\r') : (end += 1) {}
            self.executeScriptLine(data[start..end]);
            start = end;
            while (start < data.len and (data[start] == '\n' or data[start] == '\r')) : (start += 1) {}
        }
    }

    fn executeScriptLine(self: *TerminalState, raw: []const u8) void {
        var line = trim(raw);
        if (line.len == 0) return;
        var silent = false;
        if (line[0] == '@') {
            silent = true;
            line = trim(line[1..]);
            if (line.len == 0) return;
        }
        if (line[0] == ':') return;
        const parsed = splitCommand(line);
        if (equalsIgnoreCase(parsed.name, "REM")) return;
        if (self.echo_on and !silent) self.println(line);
        self.executeLine(line);
    }

    fn printPrompt(self: *TerminalState) void {
        const prompt = self.prompt_env[0..self.prompt_len];
        var i: usize = 0;
        while (i < prompt.len) : (i += 1) {
            if (prompt[i] == '$' and i + 1 < prompt.len) {
                i += 1;
                self.printPromptCode(upper(prompt[i]));
            } else {
                self.putc(prompt[i]);
            }
        }
    }

    fn printPromptCode(self: *TerminalState, code: u8) void {
        switch (code) {
            'P' => self.write(self.cwd_env[0..self.cwd_len]),
            'G' => self.putc('>'),
            'L' => self.putc('<'),
            'B' => self.putc('|'),
            'Q' => self.putc('='),
            '$' => self.putc('$'),
            '_' => self.write("\r\n"),
            else => {
                self.putc('$');
                self.putc(code);
            },
        }
    }

    fn pathCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len == 0) {
            self.write("PATH=");
            self.println(self.path_env[0..self.path_len]);
            self.setErrorlevel(0);
            return .ok;
        }

        if (equalsIgnoreCase(arg, "/?")) {
            self.println("PATH                Show the current session PATH");
            self.println("PATH <value>        Set the current session PATH");
            self.println("PATH /P             Show the persistent system PATH");
            self.println("PATH /P <value>     Set persistent PATH and update this session");
            self.println("PATH /SAVE          Save the current session PATH as persistent");
            self.println("PATH /LOAD          Load persistent PATH into this session");
            self.setErrorlevel(0);
            return .ok;
        }

        if (equalsIgnoreCase(arg, "/SAVE")) return self.savePersistentPath(self.path_env[0..self.path_len], false);
        if (equalsIgnoreCase(arg, "/LOAD")) return self.loadPersistentPathCommand();

        const parsed = splitCommand(arg);
        if (equalsIgnoreCase(parsed.name, "/P")) {
            if (parsed.args.len == 0) return self.printPersistentPath();
            return self.savePersistentPath(parsed.args, true);
        }

        if (!self.setPath(arg)) return self.fail("PATH value too long");
        self.setErrorlevel(0);
        return .ok;
    }

    fn promptCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len == 0) {
            self.write("PROMPT=");
            self.println(self.prompt_env[0..self.prompt_len]);
            self.setErrorlevel(0);
            return .ok;
        }
        if (!self.setPrompt(arg)) return self.fail("PROMPT value too long");
        self.setErrorlevel(0);
        return .ok;
    }

    fn setCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len == 0) {
            self.printEnvironment();
            self.setErrorlevel(0);
            return .ok;
        }
        const eq = findChar(arg, '=') orelse return self.fail("SET syntax: SET NAME=VALUE");
        const name = trim(arg[0..eq]);
        const value = trim(arg[eq + 1 ..]);
        if (equalsIgnoreCase(name, "PATH")) {
            if (!self.setPath(value)) return self.fail("PATH value too long");
        } else if (equalsIgnoreCase(name, "PROMPT")) {
            if (!self.setPrompt(value)) return self.fail("PROMPT value too long");
        } else if (equalsIgnoreCase(name, "SHELL")) {
            if (!self.setShell(value)) return self.fail("SHELL value too long");
        } else if (equalsIgnoreCase(name, "TEMP")) {
            if (!self.setTemp(value)) return self.fail("TEMP value too long");
        } else if (equalsIgnoreCase(name, "BLASTER")) {
            if (!self.setBlaster(value)) return self.fail("BLASTER value too long");
        } else {
            return self.fail("Unsupported environment variable");
        }
        self.setErrorlevel(0);
        return .ok;
    }

    fn desktopCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len != 0) return self.fail("DESKTOP takes no arguments");

        switch (self.sys.programCurrentConsoleHost()) {
            .terminal_mode => {
                const rc = self.sys.programRequestDesktop();
                if (rc != 0) return self.fail("Desktop host not available");
                self.setErrorlevel(0);
                return .ok;
            },
            .terminal_window => return self.fail("DESKTOP is only available in Terminal Mode"),
            .none => return self.fail("Desktop host not available"),
        }
    }

    fn cdCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len == 0) {
            self.println(self.cwd_env[0..self.cwd_len]);
            self.setErrorlevel(0);
            return .ok;
        }
        var path_buf: [PATH_MAX]u8 = undefined;
        const resolved = self.resolveDirectoryArgument(arg, path_buf[0..]) orelse return self.fail("Path not found");
        if (!self.directoryReady(resolved)) return self.fail("Path not found");
        if (!self.setCwd(resolved)) return self.fail("Path too long");
        self.setErrorlevel(0);
        return .ok;
    }

    fn printEnvironment(self: *TerminalState) void {
        self.printEnvLine("SHELL", self.shell_env[0..self.shell_len]);
        self.printEnvLine("PATH", self.path_env[0..self.path_len]);
        self.printEnvLine("PROMPT", self.prompt_env[0..self.prompt_len]);
        self.printEnvLine("CWD", self.cwd_env[0..self.cwd_len]);
        self.printEnvLine("TEMP", self.temp_env[0..self.temp_len]);
        if (self.blaster_len != 0) self.printEnvLine("BLASTER", self.blaster_env[0..self.blaster_len]);
        self.write("ERRORLEVEL=");
        self.writeI32(self.errorlevel);
        self.write("\r\n");
    }

    fn printEnvLine(self: *TerminalState, name: []const u8, value: []const u8) void {
        self.write(name);
        self.write("=");
        self.println(value);
    }

    fn clsCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        if (trim(arg_raw).len != 0) return self.fail("Usage: CLS");
        self.putc(0x0C);
        self.setErrorlevel(0);
        return .ok;
    }

    fn pauseCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (equalsIgnoreCase(arg, "/?")) {
            self.println("Usage: PAUSE");
            self.setErrorlevel(0);
            return .ok;
        }
        if (arg.len != 0) return self.fail("Usage: PAUSE");
        self.write("Press any key to continue . . .");
        while (self.sys.readKey() == 0) self.sys.taskYield();
        self.write("\r\n");
        self.setErrorlevel(0);
        return .ok;
    }

    fn sleepCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (equalsIgnoreCase(arg, "/?")) {
            self.println("Usage: SLEEP milliseconds");
            self.setErrorlevel(0);
            return .ok;
        }
        const ms = parseU64Decimal(arg) orelse return self.fail("Usage: SLEEP milliseconds");
        if (ms > 10 * 60 * 1000) return self.fail("SLEEP maximum is 600000 milliseconds");
        const ticks = self.sys.ticksFromMilliseconds(ms);
        if (ticks != 0) self.sys.sleepTicks(ticks);
        self.setErrorlevel(0);
        return .ok;
    }

    fn exitCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        if (trim(arg_raw).len != 0) return self.fail("Usage: EXIT");
        self.exit_requested = true;
        self.setErrorlevel(0);
        return .ok;
    }

    fn colorCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        _ = arg_raw;
        return self.fail("COLOR is unavailable until the Console color API is exported");
    }

    fn dateCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        if (trim(arg_raw).len != 0) return self.fail("DATE cannot set the system date yet");
        const state = self.sys.timeState();
        var status: r4os.abi.TimeServiceStatus = .{};
        const service_ok = self.sys.timeServiceStatus(&status) == r4os.abi.service_api_result_ok;
        const current_date = if (service_ok)
            r4std.date.Date{ .year = status.local_year, .month = status.local_month, .day = status.local_day }
        else
            r4std.date.Date{ .year = state.year, .month = state.month, .day = state.day };
        var formatted: [11]u8 = .{0} ** 11;
        const text_value = r4std.date.formatDateIso(formatted[0..], current_date);
        if (text_value.len == 0) return self.fail("DATE cannot read a valid date");
        self.write("Current date is ");
        self.write(text_value);
        if (state.valid == 0) self.write(" (fallback)");
        self.write("\r\n");
        self.setErrorlevel(0);
        return .ok;
    }

    fn timeCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        if (trim(arg_raw).len != 0) return self.fail("TIME cannot set the system time yet");
        const state = self.sys.timeState();
        var status: r4os.abi.TimeServiceStatus = .{};
        const service_ok = self.sys.timeServiceStatus(&status) == r4os.abi.service_api_result_ok;
        const seconds = if (service_ok) status.local_seconds_since_midnight else state.seconds_since_midnight;
        const clock_format = if (service_ok) @as(u32, status.clock_format) else r4os.abi.clock_format_24h;
        var formatted: [12]u8 = .{0} ** 12;
        const text_value = r4std.time.formatDisplay(formatted[0..], r4std.time.splitTime(seconds), clock_format);
        if (text_value.len == 0) return self.fail("TIME cannot read a valid time");
        self.write("Current time is ");
        self.write(text_value);
        if (state.valid == 0) self.write(" (fallback)");
        self.write("\r\n");
        self.setErrorlevel(0);
        return .ok;
    }

    fn volCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        const drive_index: u32 = if (arg.len == 0) 2 else driveIndexFromArg(arg) orelse return self.fail("Invalid drive");
        const info = self.sys.driveInfo(drive_index) orelse return self.fail("Drive not ready");
        if (info.mounted == 0) return self.fail("Drive not ready");
        self.write(" Volume in drive ");
        self.putc(if (info.letter == 0) @as(u8, 'A' + @as(u8, @intCast(drive_index))) else info.letter);
        self.write(" is ");
        const name = spanZFixed(info.name[0..]);
        self.println(if (name.len == 0) "R4OS" else name);
        self.println(" Volume Serial Number is 0000-0000");
        self.setErrorlevel(0);
        return .ok;
    }

    fn verifyCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len == 0) {
            self.write("VERIFY is ");
            self.println(if (self.verify_on) "on" else "off");
            self.setErrorlevel(0);
            return .ok;
        }
        if (equalsIgnoreCase(arg, "ON")) {
            self.verify_on = true;
            self.setErrorlevel(0);
            return .ok;
        }
        if (equalsIgnoreCase(arg, "OFF")) {
            self.verify_on = false;
            self.setErrorlevel(0);
            return .ok;
        }
        return self.fail("Must specify ON or OFF");
    }

    fn moreCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len == 0) return self.fail("Usage: MORE file");
        return self.typeCommand(arg);
    }

    fn sortCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len == 0) return self.fail("Usage: SORT file");
        if (hasWildcard(arg) or hasSwitch(arg)) return self.fail("SORT supports one plain file path");
        var path_buf: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        const path = copyZ(path_buf[0..], arg) orelse return self.fail("Path too long");
        var data: [FILE_CHUNK_MAX]u8 = undefined;
        const read = self.sys.fileRead(path, data[0..]);
        if (read < 0) return self.fail("File not found");
        const len: usize = @intCast(read);
        var lines: [SORT_LINE_MAX]LineRange = undefined;
        const count = collectLines(data[0..len], lines[0..]);
        sortLines(data[0..len], lines[0..count]);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const line = lines[i];
            self.write(data[line.start .. line.start + line.len]);
            self.write("\r\n");
        }
        self.setErrorlevel(0);
        return .ok;
    }

    fn typeCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len == 0) return self.fail("Usage: TYPE file");
        if (hasWildcard(arg)) return .not_handled;

        var path_buf: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        const path = copyZ(path_buf[0..], arg) orelse return self.fail("Path too long");
        var chunk: [FILE_CHUNK_MAX]u8 = undefined;
        var offset: u32 = 0;
        var read_any = false;
        while (true) {
            const rc = self.sys.fileReadAt(path, offset, chunk[0..]);
            if (rc < 0) {
                if (!read_any) return self.fail("File not found");
                break;
            }
            if (rc == 0) break;
            const len: usize = @intCast(rc);
            self.write(chunk[0..len]);
            read_any = true;
            offset += @intCast(len);
            if (len < chunk.len) break;
        }
        self.write("\r\n");
        self.setErrorlevel(0);
        return .ok;
    }

    fn dirCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (hasWildcard(arg) or startsWith(arg, "/")) return .not_handled;
        var display_buf: [PATH_MAX]u8 = undefined;
        const display = if (arg.len == 0)
            self.cwd_env[0..self.cwd_len]
        else
            self.resolveDirectoryArgument(arg, display_buf[0..]) orelse return self.fail("Path not found");
        if (!self.directoryReady(display)) return self.fail("Path not found");
        var path_buf: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        const path = copyZ(path_buf[0..], display) orelse return self.fail("Path too long");

        var entry_buf: [DIR_ENTRY_MAX]u8 = .{0} ** DIR_ENTRY_MAX;
        self.write("Directory of ");
        self.write(display);
        self.write("\r\n");

        var index: u32 = 2;
        var count: u32 = 0;
        while (true) : (index += 1) {
            @memset(entry_buf[0..], 0);
            const rc = self.sys.dirEntry(path, index, entry_buf[0..]);
            if (rc < 0) break;
            const full = spanZSlice(entry_buf[0..]);
            const name = baseName(full);
            if (name.len == 0) continue;
            if (rc == 1) {
                self.write(" <DIR>  ");
            } else {
                self.write("        ");
            }
            self.write(name);
            self.write("\r\n");
            count += 1;
        }

        if (count == 0) self.write(" <empty>\r\n");
        self.setErrorlevel(0);
        return .ok;
    }

    fn copyCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (hasWildcard(arg) or hasSwitch(arg) or mentionsDevice(arg)) return .not_handled;
        var first: [PATH_MAX]u8 = undefined;
        var second: [PATH_MAX]u8 = undefined;
        const parts = parseTwoArgs(arg, first[0..], second[0..]) orelse return self.fail("Usage: COPY source dest");
        var src_buf: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        var dst_buf: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        const src = copyZ(src_buf[0..], parts.first) orelse return self.fail("Path too long");
        const dst = copyZ(dst_buf[0..], parts.second) orelse return self.fail("Path too long");
        if (!self.sys.exists(src)) return self.fail("File not found");
        if (!self.copyByReadWrite(src, dst)) return self.fail("Copy failed");
        self.println("1 file(s) copied");
        self.setErrorlevel(0);
        return .ok;
    }

    fn copyByReadWrite(self: *TerminalState, src: [*:0]const u8, dst: [*:0]const u8) bool {
        var chunk: [FILE_CHUNK_MAX]u8 = undefined;
        const result = r4os.file_stream.copy(&self.sys, src, dst, chunk[0..]);
        return result.ok;
    }

    fn deleteCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len == 0) return self.fail("Required parameter missing");
        if (hasWildcard(arg) or hasSwitch(arg)) return .not_handled;
        var path_buf: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        const path = copyZ(path_buf[0..], arg) orelse return self.fail("Path too long");
        const rc = self.sys.fileDelete(path);
        if (rc <= 0) return self.fail("File not found");
        self.setErrorlevel(0);
        return .ok;
    }

    fn renameCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (hasWildcard(arg) or hasSwitch(arg)) return .not_handled;
        var first: [PATH_MAX]u8 = undefined;
        var second: [PATH_MAX]u8 = undefined;
        const parts = parseTwoArgs(arg, first[0..], second[0..]) orelse return self.fail("Usage: REN old new");
        var old_buf: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        var new_buf: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        const old_path = copyZ(old_buf[0..], parts.first) orelse return self.fail("Path too long");
        const new_path = copyZ(new_buf[0..], parts.second) orelse return self.fail("Path too long");
        const rc = self.sys.fileRename(old_path, new_path);
        if (rc <= 0) return self.fail("Rename failed");
        self.setErrorlevel(0);
        return .ok;
    }

    fn makeDirCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len == 0) return self.fail("Required parameter missing");
        var path_buf: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        const path = copyZ(path_buf[0..], arg) orelse return self.fail("Path too long");
        const rc = self.sys.dirCreate(path);
        if (rc <= 0) return self.fail("Directory create failed");
        self.setErrorlevel(0);
        return .ok;
    }

    fn removeDirCommand(self: *TerminalState, arg_raw: []const u8) BuiltinResult {
        const arg = trim(arg_raw);
        if (arg.len == 0) return self.fail("Required parameter missing");
        var path_buf: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        const path = copyZ(path_buf[0..], arg) orelse return self.fail("Path too long");
        const rc = self.sys.dirDelete(path);
        if (rc <= 0) return self.fail("Directory remove failed");
        self.setErrorlevel(0);
        return .ok;
    }

    /// Zeigt das Container-Helpfile eines Moduls an. false: kein Helpfile
    /// oder nicht lesbar - der Aufrufer reicht /? dann ans Programm durch.
    fn showContainerHelp(self: *TerminalState, program_path: []const u8) bool {
        var path_z: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        if (!copyCommandZ(path_z[0..], program_path)) return false;
        var help_buf: [4096]u8 = undefined;
        const read = self.sys.moduleResourceRead(&path_z, r4os.r4sys.module_resource_type_help, 0, null, help_buf[0..]);
        if (read == r4os.r4sys.module_resource_error_too_small) {
            self.write("Helpfile larger than the terminal help buffer (4096 bytes).\r\n");
            return true;
        }
        if (read <= 0) return false;
        const bytes = help_buf[0..@intCast(read)];
        self.write(bytes);
        if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') self.write("\r\n");
        return true;
    }

    fn fail(self: *TerminalState, message: []const u8) BuiltinResult {
        self.println(message);
        self.setErrorlevel(1);
        return .failed;
    }

    fn setErrorlevel(self: *TerminalState, value: i32) void {
        self.errorlevel = value;
    }

    fn loadStartupPersistentPath(self: *TerminalState) void {
        var buf: [ENV_VALUE_MAX]u8 = undefined;
        const read = self.readPersistentPath(buf[0..]);
        switch (read.status) {
            .ok => {
                if (!self.setPath(buf[0..read.len])) self.println("PATH: persistent PATH too long; using fallback");
            },
            .missing => {},
            .too_long => self.println("PATH: persistent PATH too long; using fallback"),
            .bad_type => self.println("PATH: persistent PATH has invalid type; using fallback"),
            .registry_error => self.println("PATH: persistent PATH unavailable; using fallback"),
        }
    }

    fn printPersistentPath(self: *TerminalState) BuiltinResult {
        var buf: [ENV_VALUE_MAX]u8 = undefined;
        const read = self.readPersistentPath(buf[0..]);
        switch (read.status) {
            .ok => {
                self.write("PATH /P=");
                self.println(buf[0..read.len]);
                self.setErrorlevel(0);
                return .ok;
            },
            .missing => {
                self.println("Persistent PATH is not set.");
                self.write("Fallback PATH=");
                self.println(default_path);
            },
            .too_long => self.println("Persistent PATH is too long for this Terminal."),
            .bad_type => self.println("Persistent PATH has an invalid Registry type."),
            .registry_error => self.printRegistryPathError("Persistent PATH read failed", read.result),
        }
        self.setErrorlevel(1);
        return .failed;
    }

    fn loadPersistentPathCommand(self: *TerminalState) BuiltinResult {
        var buf: [ENV_VALUE_MAX]u8 = undefined;
        const read = self.readPersistentPath(buf[0..]);
        switch (read.status) {
            .ok => {
                if (!self.setPath(buf[0..read.len])) return self.fail("Persistent PATH is too long for this Terminal");
                self.println("Persistent PATH loaded.");
                self.setErrorlevel(0);
                return .ok;
            },
            .missing => self.println("Persistent PATH is not set; fallback PATH loaded."),
            .too_long => self.println("Persistent PATH is too long; fallback PATH loaded."),
            .bad_type => self.println("Persistent PATH has an invalid type; fallback PATH loaded."),
            .registry_error => self.printRegistryPathError("Persistent PATH read failed; fallback PATH loaded", read.result),
        }
        _ = self.setPath(default_path);
        self.setErrorlevel(1);
        return .failed;
    }

    fn savePersistentPath(self: *TerminalState, value_raw: []const u8, update_session: bool) BuiltinResult {
        const value = trim(value_raw);
        if (value.len > ENV_VALUE_MAX) return self.fail("PATH value too long");
        const result = self.sys.registrySetString(environment_registry_key, path_registry_value, value);
        if (result != r4os.abi.registry_api_result_ok) {
            self.printRegistryPathError("Persistent PATH write failed", result);
            self.setErrorlevel(1);
            return .failed;
        }
        if (update_session and !self.setPath(value)) return self.fail("PATH value too long");
        self.println("Persistent PATH saved.");
        self.setErrorlevel(0);
        return .ok;
    }

    fn readPersistentPath(self: *TerminalState, out: []u8) PersistentPathRead {
        var info: r4os.abi.RegistryValueInfo = .{};
        const result = self.sys.registryGetValue(environment_registry_key, path_registry_value, &info, out);
        if (result >= 0) {
            if (info.value_type != r4os.abi.registry_value_type_string) return .{ .status = .bad_type, .result = result };
            return .{ .status = .ok, .len = @intCast(result), .result = result };
        }
        if (result == r4os.abi.registry_api_result_hive_not_found or result == r4os.abi.registry_api_result_key_not_found or result == r4os.abi.registry_api_result_value_not_found) {
            return .{ .status = .missing, .result = result };
        }
        if (result == r4os.abi.registry_api_result_buffer_too_small) return .{ .status = .too_long, .result = result };
        return .{ .status = .registry_error, .result = result };
    }

    fn printRegistryPathError(self: *TerminalState, message: []const u8, result: i32) void {
        self.write(message);
        self.write(" (");
        self.writeI32(result);
        self.println(")");
    }

    fn setPath(self: *TerminalState, value: []const u8) bool {
        if (!copyText(self.path_env[0..], &self.path_len, value)) return false;
        self.syncEnvValue("PATH", self.path_env[0..self.path_len]);
        return true;
    }

    fn setPrompt(self: *TerminalState, value: []const u8) bool {
        if (!copyText(self.prompt_env[0..], &self.prompt_len, value)) return false;
        self.syncEnvValue("PROMPT", self.prompt_env[0..self.prompt_len]);
        return true;
    }

    fn setShell(self: *TerminalState, value: []const u8) bool {
        if (!copyText(self.shell_env[0..], &self.shell_len, value)) return false;
        self.syncEnvValue("SHELL", self.shell_env[0..self.shell_len]);
        return true;
    }

    fn setCwd(self: *TerminalState, value: []const u8) bool {
        if (!copyText(self.cwd_env[0..], &self.cwd_len, value)) return false;
        self.syncEnvValue("CWD", self.cwd_env[0..self.cwd_len]);
        return true;
    }

    fn changeDriveCommand(self: *TerminalState, letter: u8) BuiltinResult {
        var root_buf: [4]u8 = undefined;
        const root = driveRootPath(letter, root_buf[0..]) orelse return self.fail("Invalid drive");
        if (!self.directoryReady(root)) return self.fail("Drive not ready");
        if (!self.setCwd(root)) return self.fail("Path too long");
        self.setErrorlevel(0);
        return .ok;
    }

    fn resolveDirectoryArgument(self: *TerminalState, arg: []const u8, out: []u8) ?[]const u8 {
        return normalizeDosPath(self.cwd_env[0..self.cwd_len], arg, out);
    }

    fn directoryReady(self: *TerminalState, path: []const u8) bool {
        if (driveRootLetter(path)) |letter| {
            const index = driveIndexFromLetter(letter) orelse return false;
            const info = self.sys.driveInfo(index) orelse return false;
            return info.mounted != 0;
        }
        var path_z: [PATH_MAX:0]u8 = .{0} ** PATH_MAX;
        const z = copyZ(path_z[0..], path) orelse return false;
        const info = self.sys.fileInfo(z) orelse return false;
        return info.exists != 0 and info.is_dir != 0;
    }

    fn setTemp(self: *TerminalState, value: []const u8) bool {
        if (!copyText(self.temp_env[0..], &self.temp_len, value)) return false;
        self.syncEnvValue("TEMP", self.temp_env[0..self.temp_len]);
        return true;
    }

    fn setBlaster(self: *TerminalState, value: []const u8) bool {
        if (!copyText(self.blaster_env[0..], &self.blaster_len, value)) return false;
        self.syncEnvValue("BLASTER", self.blaster_env[0..self.blaster_len]);
        return true;
    }

    fn syncProcessEnvironment(self: *TerminalState) void {
        self.syncEnvValue("PATH", self.path_env[0..self.path_len]);
        self.syncEnvValue("PROMPT", self.prompt_env[0..self.prompt_len]);
        self.syncEnvValue("SHELL", self.shell_env[0..self.shell_len]);
        self.syncEnvValue("CWD", self.cwd_env[0..self.cwd_len]);
        self.syncEnvValue("TEMP", self.temp_env[0..self.temp_len]);
        self.syncEnvValue("BLASTER", self.blaster_env[0..self.blaster_len]);
    }

    fn syncEnvValue(self: *TerminalState, name: [*:0]const u8, value: []const u8) void {
        _ = self.sys.envSet(name, value);
    }

    fn writeI32(self: *TerminalState, value: i32) void {
        var buf: [12]u8 = undefined;
        var pos: usize = buf.len;
        var n: u32 = undefined;
        if (value < 0) {
            n = @intCast(-value);
        } else {
            n = @intCast(value);
        }
        if (n == 0) {
            pos -= 1;
            buf[pos] = '0';
        } else {
            while (n != 0) {
                pos -= 1;
                buf[pos] = @intCast('0' + (n % 10));
                n /= 10;
            }
        }
        if (value < 0) {
            pos -= 1;
            buf[pos] = '-';
        }
        self.write(buf[pos..]);
    }

    fn writeU32Padded(self: *TerminalState, value: u32, width: usize) void {
        var buf: [10]u8 = .{'0'} ** 10;
        var pos: usize = buf.len;
        var n = value;
        while (pos > 0) {
            pos -= 1;
            buf[pos] = @intCast('0' + (n % 10));
            n /= 10;
            if (n == 0 and buf.len - pos >= width) break;
        }
        self.write(buf[pos..]);
    }

    fn addHistory(self: *TerminalState, line: []const u8) void {
        const cleaned = trim(line);
        if (cleaned.len == 0) return;
        if (self.history_count != 0) {
            const latest = self.historyIndexFromAge(0);
            if (self.history_lens[latest] == cleaned.len and equalsIgnoreCase(self.history[latest][0..self.history_lens[latest]], cleaned)) return;
        }
        const count = if (cleaned.len < INPUT_MAX) cleaned.len else INPUT_MAX;
        @memcpy(self.history[self.history_next][0..count], cleaned[0..count]);
        self.history_lens[self.history_next] = count;
        self.history_next = (self.history_next + 1) % HISTORY_DEPTH;
        if (self.history_count < HISTORY_DEPTH) self.history_count += 1;
    }

    fn previousHistoryAge(self: *TerminalState, current: ?usize) ?usize {
        if (self.history_count == 0) return null;
        const age = current orelse return 0;
        if (age + 1 >= self.history_count) return age;
        return age + 1;
    }

    fn nextHistoryAge(_: *TerminalState, current: ?usize) ?usize {
        const age = current orelse return null;
        if (age == 0) return null;
        return age - 1;
    }

    fn replaceInputFromHistory(self: *TerminalState, age: usize, input: []u8, len: *usize) void {
        const index = self.historyIndexFromAge(age);
        self.clearInputLine(len.*);
        const new_len = self.history_lens[index];
        @memcpy(input[0..new_len], self.history[index][0..new_len]);
        len.* = new_len;
        self.write(input[0..new_len]);
    }

    fn clearInputLine(self: *TerminalState, len: usize) void {
        var i: usize = 0;
        while (i < len) : (i += 1) self.putc(0x08);
    }

    fn historyIndexFromAge(self: *TerminalState, age: usize) usize {
        return (self.history_next + HISTORY_DEPTH - 1 - age) % HISTORY_DEPTH;
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    if (!r4std.init(r4_app.startContext())) return r4os.abi.err_no_group;
    const sys = r4_app.system();
    const dev = r4_app.devicesLowLevel() orelse return r4os.abi.err_no_group;
    const args = zSpan(sys.argsRaw());
    if (commandFromArgs(args)) |command| return runCommand(sys, dev, command);
    return switch (modeFromArgs(args)) {
        .primary => runPrimary(sys, dev, true),
        .primary_no_autoexec => runPrimary(sys, dev, false),
        .help => runHelp(sys),
        .selftest => runSelftest(sys, dev),
        .builtintest => runBuiltinSelftest(sys, dev),
        .launchtest => runLaunchSelftest(sys, dev),
        .batchtest => runBatchSelftest(sys, dev),
    };
}

fn runPrimary(sys: r4os.r4sys.Context, dev: r4os.r4dev.Context, run_autoexec: bool) i32 {
    var state = TerminalState{ .sys = sys, .dev = dev };
    return state.run(run_autoexec);
}

fn runCommand(sys: r4os.r4sys.Context, dev: r4os.r4dev.Context, command: []const u8) i32 {
    var state = TerminalState{ .sys = sys, .dev = dev };
    state.initializeSession();
    state.executeLine(command);
    return state.errorlevel;
}

fn runHelp(sys: r4os.r4sys.Context) i32 {
    sys.println("TERMINAL.R4X - R4OS terminal shell");
    sys.println("Usage: TERMINAL.R4X [/?] [/NOAUTOEXEC] [/C command] [/SELFTEST] [/BUILTINTEST] [/LAUNCHTEST] [/BATCHTEST]");
    sys.println("Default mode runs userland session, prompt, environment, input/history and simple built-ins.");
    sys.println("EXIT ends the current Terminal session.");
    sys.println("/NOAUTOEXEC starts an interactive session without C:\\AUTOEXEC.BAT.");
    sys.println("/C command runs one command through the normal Terminal command path and exits.");
    return 0;
}

fn runSelftest(sys: r4os.r4sys.Context, dev: r4os.r4dev.Context) i32 {
    var ok = true;
    if (!sys.contractValid()) {
        sys.println("Terminal selftest: API header invalid");
        ok = false;
    }
    if (!sys.base.hasDeskFn("program_set_console_host")) {
        sys.println("Terminal selftest: console-host control API missing");
        ok = false;
    }
    if (!sys.exists("C:\\R4OS\\SOFTWARE\\TERMINAL\\TERMINAL.R4X")) {
        sys.println("Terminal selftest: C:\\R4OS\\SOFTWARE\\TERMINAL\\TERMINAL.R4X missing");
        ok = false;
    }
    if (!sys.exists("C:\\AUTOEXEC.BAT")) {
        sys.println("Terminal selftest: C:\\AUTOEXEC.BAT missing");
        ok = false;
    }
    if (!ok) {
        sys.println("Terminal userland selftest: FAILED");
        return 1;
    }
    var state = TerminalState{ .sys = sys, .dev = dev };
    state.initializeSession();
    var version_data: [VERSION_FILE_MAX]u8 = undefined;
    if (equalsIgnoreCase(state.releaseVersion(version_data[0..]), version_unknown)) {
        sys.println("Terminal selftest: VERSION.R4S not readable");
        ok = false;
    }
    ok = state.path_len != 0 and state.shell_len != 0 and state.prompt_len != 0 and state.cwd_len != 0 and ok;
    state.setErrorlevel(7);
    ok = state.errorlevel == 7 and ok;
    state.setErrorlevel(0);
    ok = equalsIgnoreCase(state.path_env[0..state.path_len], default_path) and ok;
    ok = expectBuiltin(&state, "PATH C:\\R4OS\\SOFTWARE\\TERMINAL;C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG") and ok;
    ok = equalsIgnoreCase(state.path_env[0..state.path_len], "C:\\R4OS\\SOFTWARE\\TERMINAL;C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG") and ok;
    const too_long_path: [ENV_VALUE_MAX + 1]u8 = .{'X'} ** (ENV_VALUE_MAX + 1);
    ok = !state.setPath(too_long_path[0..]) and ok;
    ok = equalsIgnoreCase(state.path_env[0..state.path_len], "C:\\R4OS\\SOFTWARE\\TERMINAL;C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG") and ok;
    ok = expectBuiltin(&state, "PROMPT $P$G") and ok;
    ok = expectBuiltin(&state, "SET TEMP=C:\\TEMP") and ok;
    ok = expectBuiltin(&state, "SET SHELL=C:\\R4OS\\SOFTWARE\\TERMINAL\\TERMINAL.R4X") and ok;
    ok = expectFailure(&state, "DESKTOP EXTRA") and ok;
    ok = expectCommandFailure(&state, "DESK") and ok;
    if (sys.exists("C:\\R4OS\\SOFTWARE\\DESKTOP\\R4DESK.R4X")) {
        ok = expectCommandFailure(&state, "C:\\R4OS\\SOFTWARE\\DESKTOP\\R4DESK.R4X /NOHOSTTEST") and ok;
    }
    ok = expectBuiltin(&state, "CD C:\\") and ok;
    ok = expectCwd(&state, "C:\\") and ok;
    ok = expectBuiltin(&state, "CD R4OS") and ok;
    ok = expectCwd(&state, "C:\\R4OS") and ok;
    ok = expectBuiltin(&state, "CD ..") and ok;
    ok = expectCwd(&state, "C:\\") and ok;
    ok = expectFailure(&state, "CD IRGENDWAS") and ok;
    ok = expectCwd(&state, "C:\\") and ok;
    if (state.directoryReady("D:\\")) {
        ok = expectCommandOk(&state, "D:") and ok;
        ok = expectCwd(&state, "D:\\") and ok;
        ok = expectBuiltin(&state, "CD C:") and ok;
        ok = expectCwd(&state, "C:\\") and ok;
    }
    if (!ok) {
        sys.println("Terminal userland session selftest: FAILED");
        return 1;
    }
    if (runBuiltinSelftest(sys, dev) != 0) return 1;
    sys.println("Terminal userland selftest: OK");
    sys.println("Terminal loop: userland session/prompt/environment/input/history/built-ins/external launch/batch/redirection");
    return 0;
}

fn runBuiltinSelftest(sys: r4os.r4sys.Context, dev: r4os.r4dev.Context) i32 {
    var state = TerminalState{ .sys = sys, .dev = dev };
    state.initializeSession();
    var ok = true;

    _ = sys.fileDelete("C:\\CMDTEST\\CMDU.TXT");
    _ = sys.fileDelete("C:\\CMDTEST\\CMDU2.TXT");
    _ = sys.fileDelete("C:\\CMDTEST\\CMDU3.TXT");
    _ = sys.fileDelete("C:\\CMDTEST\\SORT.TXT");
    _ = sys.dirDelete("C:\\CMDTEST");
    ok = expectBuiltin(&state, "MD C:\\CMDTEST") and ok;
    ok = expectBuiltin(&state, "CD CMDTEST") and ok;
    ok = expectCwd(&state, "C:\\CMDTEST") and ok;
    ok = expectBuiltin(&state, "DIR") and ok;
    ok = expectFailure(&state, "CD NO_SUCH_DIR") and ok;
    ok = expectCwd(&state, "C:\\CMDTEST") and ok;
    ok = expectBuiltin(&state, "CD ..") and ok;
    ok = expectCwd(&state, "C:\\") and ok;
    ok = writeFixture(sys, "C:\\CMDTEST\\CMDU.TXT", "TERMINAL USERLAND\r\n") and ok;
    ok = writeFixture(sys, "C:\\CMDTEST\\SORT.TXT", "zeta\r\nalpha\r\nBeta\r\n") and ok;
    ok = expectBuiltin(&state, "CLS") and ok;
    ok = expectBuiltin(&state, "VERIFY") and ok;
    ok = expectBuiltin(&state, "VERIFY ON") and ok;
    ok = state.verify_on and ok;
    ok = expectBuiltin(&state, "VERIFY OFF") and ok;
    ok = !state.verify_on and ok;
    ok = expectBuiltin(&state, "DATE") and ok;
    ok = expectBuiltin(&state, "TIME") and ok;
    ok = expectBuiltin(&state, "VOL") and ok;
    ok = expectBuiltin(&state, "PAUSE /?") and ok;
    ok = expectBuiltin(&state, "SLEEP 0") and ok;
    ok = expectBuiltin(&state, "ECHO Terminal userland builtin echo") and ok;
    ok = expectBuiltin(&state, "VER") and ok;
    ok = expectBuiltin(&state, "TYPE C:\\CMDTEST\\CMDU.TXT") and ok;
    ok = expectBuiltin(&state, "MORE C:\\CMDTEST\\CMDU.TXT") and ok;
    ok = expectBuiltin(&state, "SORT C:\\CMDTEST\\SORT.TXT") and ok;
    ok = expectBuiltin(&state, "DIR C:\\CMDTEST") and ok;
    ok = expectBuiltin(&state, "COPY C:\\CMDTEST\\CMDU.TXT C:\\CMDTEST\\CMDU2.TXT") and ok;
    ok = sys.exists("C:\\CMDTEST\\CMDU2.TXT") and ok;
    ok = expectBuiltin(&state, "DEL C:\\CMDTEST\\CMDU2.TXT") and ok;
    ok = !sys.exists("C:\\CMDTEST\\CMDU2.TXT") and ok;
    ok = expectBuiltin(&state, "REN C:\\CMDTEST\\CMDU.TXT C:\\CMDTEST\\CMDU3.TXT") and ok;
    ok = sys.exists("C:\\CMDTEST\\CMDU3.TXT") and ok;
    ok = expectBuiltin(&state, "DEL C:\\CMDTEST\\CMDU3.TXT") and ok;
    ok = expectFailure(&state, "TYPE C:\\CMDTEST\\MISSING.TXT") and ok;
    ok = state.errorlevel == 1 and ok;
    ok = expectFailure(&state, "COPY C:\\CMDTEST\\MISSING.TXT C:\\CMDTEST\\NOPE.TXT") and ok;
    ok = expectFailure(&state, "MD") and ok;
    ok = expectFailure(&state, "COLOR 1F") and ok;
    ok = expectFailure(&state, "TYPE C:\\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.TXT") and ok;
    ok = expectBuiltin(&state, "DEL C:\\CMDTEST\\SORT.TXT") and ok;
    ok = expectBuiltin(&state, "RD C:\\CMDTEST") and ok;

    if (!ok) {
        sys.println("Terminal builtins selftest: FAILED");
        return 1;
    }
    sys.println("Terminal builtins: userland echo/ver/type/dir/copy/del/ren/md/rd OK");
    return 0;
}

fn runLaunchSelftest(sys: r4os.r4sys.Context, dev: r4os.r4dev.Context) i32 {
    var state = TerminalState{ .sys = sys, .dev = dev };
    state.initializeSession();
    var ok = true;

    ok = expectProgramResolution(&state, "BOOTINFO", 1) and ok;
    ok = expectProgramResolution(&state, "BOOTINFO.R4X", 1) and ok;
    ok = expectProgramResolution(&state, "C:\\R4OS\\SOFTWARE\\TERMINAL\\BOOTINFO.R4X", 1) and ok;
    ok = expectProgramResolution(&state, "R4OS\\SOFTWARE\\TERMINAL\\BOOTINFO.R4X", 1) and ok;
    ok = expectCommandFailure(&state, "NO_SUCH_COMMAND") and ok;

    if (!ok) {
        sys.println("Terminal launch selftest: FAILED");
        return 1;
    }
    sys.println("Terminal launch: userland external program resolution OK");
    return 0;
}

fn runBatchSelftest(sys: r4os.r4sys.Context, dev: r4os.r4dev.Context) i32 {
    var state = TerminalState{ .sys = sys, .dev = dev };
    state.initializeSession();
    var ok = true;

    _ = sys.fileDelete("C:\\CMDTEST\\REDIR.TXT");
    _ = sys.fileDelete("C:\\CMDTEST\\REDIR2.TXT");
    _ = sys.fileDelete("C:\\CMDTEST\\BATCHT.BAT");
    _ = sys.fileDelete("C:\\CMDTEST\\BATCH.OUT");
    _ = sys.dirDelete("C:\\CMDTEST");

    ok = checkBatchStep(sys, "mkdir", expectBuiltin(&state, "MD C:\\CMDTEST")) and ok;
    state.executeLine("ECHO FIRST > C:\\CMDTEST\\REDIR.TXT");
    ok = checkBatchStep(sys, "redirect truncate", state.errorlevel == 0 and fileContains(sys, "C:\\CMDTEST\\REDIR.TXT", "FIRST\r\n")) and ok;
    state.executeLine("ECHO SECOND >> C:\\CMDTEST\\REDIR.TXT");
    ok = checkBatchStep(sys, "redirect append", state.errorlevel == 0 and fileContains(sys, "C:\\CMDTEST\\REDIR.TXT", "FIRST\r\nSECOND\r\n")) and ok;
    state.executeLine("TYPE C:\\CMDTEST\\REDIR.TXT > C:\\CMDTEST\\REDIR2.TXT");
    ok = checkBatchStep(sys, "redirect type", state.errorlevel == 0 and fileStartsWith(sys, "C:\\CMDTEST\\REDIR2.TXT", "FIRST\r\nSECOND\r\n")) and ok;
    ok = checkBatchStep(sys, "write batch fixture", writeFixture(sys, "C:\\CMDTEST\\BATCHT.BAT", "@ECHO OFF\r\nREM BATCH TEST\r\nECHO BATCH-OK > C:\\CMDTEST\\BATCH.OUT\r\n")) and ok;
    state.executeLine("C:\\CMDTEST\\BATCHT.BAT");
    ok = checkBatchStep(sys, "run batch file", state.errorlevel == 0 and fileContains(sys, "C:\\CMDTEST\\BATCH.OUT", "BATCH-OK\r\n")) and ok;
    state.executeLine("ECHO X | MORE");
    ok = checkBatchStep(sys, "pipe rejection", state.errorlevel != 0) and ok;
    state.executeLine("SORT < C:\\CMDTEST\\REDIR.TXT");
    ok = checkBatchStep(sys, "stdin rejection", state.errorlevel != 0) and ok;
    state.executeLine("BOOTINFO > C:\\CMDTEST\\BOOTINFO.TXT");
    ok = checkBatchStep(sys, "external redirection rejection", state.errorlevel != 0) and ok;
    ok = checkBatchStep(sys, "batch control rejection", expectFailure(&state, "GOTO END")) and ok;

    _ = sys.fileDelete("C:\\CMDTEST\\BOOTINFO.TXT");
    _ = sys.fileDelete("C:\\CMDTEST\\BATCH.OUT");
    _ = sys.fileDelete("C:\\CMDTEST\\BATCHT.BAT");
    _ = sys.fileDelete("C:\\CMDTEST\\REDIR2.TXT");
    _ = sys.fileDelete("C:\\CMDTEST\\REDIR.TXT");
    _ = sys.dirDelete("C:\\CMDTEST");

    if (!ok) {
        sys.println("Terminal batch/redirection selftest: FAILED");
        return 1;
    }
    sys.println("Terminal batch/redirection: userland basics OK");
    return 0;
}

fn checkBatchStep(sys: r4os.r4sys.Context, name: []const u8, ok: bool) bool {
    if (!ok) {
        sys.write("Terminal batch/redirection check failed: ");
        sys.println(name);
    }
    return ok;
}

fn expectBuiltin(state: *TerminalState, cmd: []const u8) bool {
    return state.executeUserlandBuiltin(cmd) == .ok;
}

fn expectFailure(state: *TerminalState, cmd: []const u8) bool {
    return state.executeUserlandBuiltin(cmd) == .failed;
}

fn expectCommandOk(state: *TerminalState, cmd: []const u8) bool {
    state.executeLine(cmd);
    return state.errorlevel == 0;
}

fn expectCommandFailure(state: *TerminalState, cmd: []const u8) bool {
    state.executeLine(cmd);
    return state.errorlevel != 0;
}

fn expectCwd(state: *TerminalState, expected: []const u8) bool {
    return equalsIgnoreCase(state.cwd_env[0..state.cwd_len], expected);
}

fn expectProgramResolution(state: *TerminalState, name: []const u8, expected_class: i32) bool {
    var path_buf: [PATH_MAX]u8 = undefined;
    const resolved = state.resolveExternalProgram(name, path_buf[0..]) orelse return false;
    return resolved.class_id == expected_class;
}

fn writeFixture(sys: r4os.r4sys.Context, path: [*:0]const u8, data: []const u8) bool {
    return sys.fileWrite(path, data) == @as(i32, @intCast(data.len));
}

fn fileContains(sys: r4os.r4sys.Context, path: [*:0]const u8, expected: []const u8) bool {
    var buf: [FILE_CHUNK_MAX]u8 = undefined;
    const read = sys.fileRead(path, buf[0..]);
    if (read < 0) return false;
    const len: usize = @intCast(read);
    return len == expected.len and equalsBytes(buf[0..len], expected);
}

fn fileStartsWith(sys: r4os.r4sys.Context, path: [*:0]const u8, expected: []const u8) bool {
    var buf: [FILE_CHUNK_MAX]u8 = undefined;
    const read = sys.fileRead(path, buf[0..]);
    if (read < 0) return false;
    const len: usize = @intCast(read);
    if (len < expected.len) return false;
    return equalsBytes(buf[0..expected.len], expected);
}

fn modeFromArgs(args_raw: []const u8) Mode {
    const args = trim(args_raw);
    if (args.len == 0) return .primary;
    if (equalsIgnoreCase(args, "/NOAUTOEXEC") or equalsIgnoreCase(args, "--NOAUTOEXEC") or equalsIgnoreCase(args, "--NO-AUTOEXEC")) return .primary_no_autoexec;
    if (equalsIgnoreCase(args, "/?") or equalsIgnoreCase(args, "-?") or equalsIgnoreCase(args, "/HELP") or equalsIgnoreCase(args, "--HELP")) return .help;
    if (equalsIgnoreCase(args, "/SELFTEST") or equalsIgnoreCase(args, "--SELFTEST")) return .selftest;
    if (equalsIgnoreCase(args, "/BUILTINTEST") or equalsIgnoreCase(args, "--BUILTINTEST")) return .builtintest;
    if (equalsIgnoreCase(args, "/LAUNCHTEST") or equalsIgnoreCase(args, "--LAUNCHTEST")) return .launchtest;
    if (equalsIgnoreCase(args, "/BATCHTEST") or equalsIgnoreCase(args, "--BATCHTEST")) return .batchtest;
    return .help;
}

fn commandFromArgs(args_raw: []const u8) ?[]const u8 {
    const args = trim(args_raw);
    if (args.len == 0) return null;
    if (commandAfterSwitch(args)) |command| return command;

    const split = firstSpace(args) orelse return null;
    const first = trim(args[0..split]);
    if (!isNoAutoexecSwitch(first)) return null;
    return commandAfterSwitch(trim(args[split + 1 ..]));
}

fn commandAfterSwitch(args: []const u8) ?[]const u8 {
    const trimmed = trim(args);
    if (trimmed.len == 0) return null;
    const split = firstSpace(trimmed) orelse {
        if (isCommandSwitch(trimmed)) return "";
        return null;
    };
    const first = trim(trimmed[0..split]);
    if (!isCommandSwitch(first)) return null;
    return trim(trimmed[split + 1 ..]);
}

fn isCommandSwitch(value: []const u8) bool {
    return equalsIgnoreCase(value, "/C") or equalsIgnoreCase(value, "-C") or equalsIgnoreCase(value, "--COMMAND");
}

fn isNoAutoexecSwitch(value: []const u8) bool {
    return equalsIgnoreCase(value, "/NOAUTOEXEC") or equalsIgnoreCase(value, "--NOAUTOEXEC") or equalsIgnoreCase(value, "--NO-AUTOEXEC");
}

fn zSpan(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r' or s[start] == '\n')) : (start += 1) {}
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) : (end -= 1) {}
    return s[start..end];
}

fn stripBom(data: []const u8) []const u8 {
    if (data.len >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) return data[3..];
    return data;
}

fn copyText(out: []u8, len: *usize, text: []const u8) bool {
    if (text.len > out.len) return false;
    @memset(out, 0);
    if (text.len > 0) @memcpy(out[0..text.len], text);
    len.* = text.len;
    return true;
}

fn findChar(text: []const u8, needle: u8) ?usize {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == needle) return i;
    }
    return null;
}

fn driveIndexFromArg(arg: []const u8) ?u32 {
    if (arg.len == 0) return null;
    const letter = upper(arg[0]);
    if (letter < 'A' or letter > 'Z') return null;
    if (arg.len > 1 and arg[1] != ':') return null;
    return @intCast(letter - 'A');
}

fn driveSwitchLetter(cmd: []const u8) ?u8 {
    const text = trim(cmd);
    if (text.len != 2 or text[1] != ':') return null;
    const letter = upper(text[0]);
    if (letter < 'A' or letter > 'Z') return null;
    return letter;
}

fn driveIndexFromLetter(letter_raw: u8) ?u32 {
    const letter = upper(letter_raw);
    if (letter < 'A' or letter > 'Z') return null;
    return @intCast(letter - 'A');
}

fn driveRootPath(letter_raw: u8, out: []u8) ?[]const u8 {
    const letter = upper(letter_raw);
    if (letter < 'A' or letter > 'Z' or out.len < 3) return null;
    out[0] = letter;
    out[1] = ':';
    out[2] = '\\';
    return out[0..3];
}

fn driveRootLetter(path: []const u8) ?u8 {
    if (path.len != 3 or path[1] != ':' or !isPathSeparator(path[2])) return null;
    const letter = upper(path[0]);
    if (letter < 'A' or letter > 'Z') return null;
    return letter;
}

fn currentDriveLetter(cwd: []const u8) u8 {
    if (cwd.len >= 2 and cwd[1] == ':') {
        const letter = upper(cwd[0]);
        if (letter >= 'A' and letter <= 'Z') return letter;
    }
    return 'C';
}

fn normalizeDosPath(cwd_raw: []const u8, arg_raw: []const u8, out: []u8) ?[]const u8 {
    const arg = trim(arg_raw);
    if (arg.len == 0) return null;

    var drive = currentDriveLetter(cwd_raw);
    var rest = arg;
    var absolute = false;

    if (arg.len >= 2 and arg[1] == ':') {
        drive = upper(arg[0]);
        if (drive < 'A' or drive > 'Z') return null;
        rest = arg[2..];
        absolute = true;
        if (rest.len != 0 and isPathSeparator(rest[0])) rest = skipLeadingSeparators(rest);
    } else if (isPathSeparator(arg[0])) {
        absolute = true;
        rest = skipLeadingSeparators(arg);
    }

    var len: usize = 0;
    if (absolute) {
        if (!appendRoot(out, &len, drive)) return null;
    } else {
        const cwd = trim(cwd_raw);
        if (cwd.len >= 3 and cwd[1] == ':' and isPathSeparator(cwd[2])) {
            if (cwd.len > out.len) return null;
            @memcpy(out[0..cwd.len], cwd);
            len = cwd.len;
        } else {
            if (!appendRoot(out, &len, drive)) return null;
        }
    }

    if (!appendNormalizedSegments(out, &len, rest)) return null;
    return out[0..len];
}

fn appendRoot(out: []u8, len: *usize, letter: u8) bool {
    if (out.len < 3) return false;
    out[0] = letter;
    out[1] = ':';
    out[2] = '\\';
    len.* = 3;
    return true;
}

fn appendNormalizedSegments(out: []u8, len: *usize, text: []const u8) bool {
    var start: usize = 0;
    while (start < text.len) {
        while (start < text.len and isPathSeparator(text[start])) : (start += 1) {}
        const seg_start = start;
        while (start < text.len and !isPathSeparator(text[start])) : (start += 1) {}
        const segment = text[seg_start..start];
        if (segment.len == 0 or equalsBytes(segment, ".")) {
            continue;
        }
        if (equalsBytes(segment, "..")) {
            popPathSegment(out, len);
            continue;
        }
        if (len.* > 3) {
            if (!appendByteChecked(out, len, '\\')) return false;
        }
        if (!appendChecked(out, len, segment)) return false;
    }
    return true;
}

fn popPathSegment(out: []const u8, len: *usize) void {
    if (len.* <= 3) {
        len.* = 3;
        return;
    }
    var i = len.*;
    while (i > 3) : (i -= 1) {
        if (isPathSeparator(out[i - 1])) {
            len.* = if (i <= 4) 3 else i - 1;
            return;
        }
    }
    len.* = 3;
}

fn skipLeadingSeparators(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and isPathSeparator(text[start])) : (start += 1) {}
    return text[start..];
}

fn isPathSeparator(ch: u8) bool {
    return ch == '\\' or ch == '/';
}

fn spanZFixed(bytes: []const u8) []const u8 {
    var len: usize = 0;
    while (len < bytes.len and bytes[len] != 0) : (len += 1) {}
    return bytes[0..len];
}

fn collectLines(data: []const u8, out: []LineRange) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (start < data.len and count < out.len) {
        var end = start;
        while (end < data.len and data[end] != '\n' and data[end] != '\r') : (end += 1) {}
        out[count] = .{ .start = start, .len = trimLineLen(data[start..end]) };
        count += 1;
        start = end;
        while (start < data.len and (data[start] == '\n' or data[start] == '\r')) : (start += 1) {}
    }
    return count;
}

fn trimLineLen(line: []const u8) usize {
    var end = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}
    return end;
}

fn sortLines(data: []const u8, lines: []LineRange) void {
    var i: usize = 1;
    while (i < lines.len) : (i += 1) {
        const item = lines[i];
        var j = i;
        while (j > 0 and lineLess(data, item, lines[j - 1])) : (j -= 1) {
            lines[j] = lines[j - 1];
        }
        lines[j] = item;
    }
}

fn lineLess(data: []const u8, a: LineRange, b: LineRange) bool {
    const left = data[a.start .. a.start + a.len];
    const right = data[b.start .. b.start + b.len];
    const n = @min(left.len, right.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const lc = upper(left[i]);
        const rc = upper(right[i]);
        if (lc < rc) return true;
        if (lc > rc) return false;
    }
    return left.len < right.len;
}

fn containsPipeSyntax(text: []const u8) bool {
    return findChar(text, '|') != null;
}

fn containsRedirectionSyntax(text: []const u8) bool {
    return findChar(text, '>') != null or findChar(text, '<') != null;
}

fn parseRedirection(cmd: []const u8) ?RedirectCommand {
    var i: usize = 0;
    while (i < cmd.len) : (i += 1) {
        if (cmd[i] == '<') {
            return .{ .command = trim(cmd[0..i]), .target = trim(cmd[i + 1 ..]), .mode = .stdin };
        }
        if (cmd[i] == '>') {
            const append = i + 1 < cmd.len and cmd[i + 1] == '>';
            const target_start = i + if (append) @as(usize, 2) else @as(usize, 1);
            const target = trim(cmd[target_start..]);
            if (!singleTokenOnly(target)) return null;
            return .{
                .command = trim(cmd[0..i]),
                .target = target,
                .mode = if (append) .stdout_append else .stdout_truncate,
            };
        }
    }
    return null;
}

fn singleTokenOnly(text: []const u8) bool {
    if (text.len == 0) return false;
    var pos: usize = 0;
    _ = nextToken(text, &pos) orelse return false;
    return nextToken(text, &pos) == null;
}

fn hasProgramPathSyntax(name: []const u8) bool {
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == ':' or name[i] == '\\' or name[i] == '/') return true;
    }
    return false;
}

fn isAbsoluteDosPath(name: []const u8) bool {
    if (name.len >= 2 and name[1] == ':') return true;
    return name.len != 0 and (name[0] == '\\' or name[0] == '/');
}

fn hasR4XExtension(name: []const u8) bool {
    if (name.len < PROGRAM_EXT.len) return false;
    return equalsIgnoreCase(name[name.len - PROGRAM_EXT.len ..], PROGRAM_EXT);
}

fn isDesktopShellProgram(path: []const u8) bool {
    return equalsIgnoreCase(baseName(path), "R4DESK.R4X");
}

fn hasBatchExtension(name: []const u8) bool {
    if (name.len < BATCH_EXT.len) return false;
    return equalsIgnoreCase(name[name.len - BATCH_EXT.len ..], BATCH_EXT);
}

fn appendProgramExtension(name: []const u8, out: []u8) ?[]const u8 {
    var len: usize = 0;
    if (!appendChecked(out, &len, name)) return null;
    if (!appendChecked(out, &len, PROGRAM_EXT)) return null;
    return out[0..len];
}

fn appendBatchExtension(name: []const u8, out: []u8) ?[]const u8 {
    var len: usize = 0;
    if (!appendChecked(out, &len, name)) return null;
    if (!appendChecked(out, &len, BATCH_EXT)) return null;
    return out[0..len];
}

fn joinDosPath(dir_raw: []const u8, name: []const u8, out: []u8) ?[]const u8 {
    const dir = trim(dir_raw);
    if (name.len == 0) return null;
    if (isAbsoluteDosPath(name)) {
        if (name.len >= out.len) return null;
        @memcpy(out[0..name.len], name);
        return out[0..name.len];
    }
    var len: usize = 0;
    if (dir.len != 0) {
        if (!appendChecked(out, &len, dir)) return null;
        const last = dir[dir.len - 1];
        if (last != '\\' and last != '/') {
            if (!appendByteChecked(out, &len, '\\')) return null;
        }
    }
    if (!appendChecked(out, &len, name)) return null;
    return out[0..len];
}

fn nextPathDirectory(path: []const u8, pos: *usize) ?[]const u8 {
    while (pos.* <= path.len) {
        while (pos.* < path.len and path[pos.*] == ';') : (pos.* += 1) {}
        if (pos.* >= path.len) return null;
        const start = pos.*;
        while (pos.* < path.len and path[pos.*] != ';') : (pos.* += 1) {}
        const end = pos.*;
        if (pos.* < path.len and path[pos.*] == ';') pos.* += 1;
        const dir = trim(path[start..end]);
        if (dir.len != 0) return dir;
    }
    return null;
}

fn appendChecked(out: []u8, len: *usize, text: []const u8) bool {
    if (text.len > out.len - len.*) return false;
    @memcpy(out[len.* .. len.* + text.len], text);
    len.* += text.len;
    return true;
}

fn appendByteChecked(out: []u8, len: *usize, value: u8) bool {
    if (len.* >= out.len) return false;
    out[len.*] = value;
    len.* += 1;
    return true;
}

fn copyCommandZ(out: []u8, text: []const u8) bool {
    if (text.len >= out.len) return false;
    if (text.len != 0) @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return true;
}

fn formatI32(value: i32, out: []u8) []const u8 {
    if (value < 0) {
        if (out.len == 0) return "";
        out[0] = '-';
        const abs_value: u64 = @intCast(-@as(i64, value));
        const rest = formatU64(abs_value, out[1..]);
        return out[0 .. 1 + rest.len];
    }
    return formatU64(@intCast(value), out);
}

fn formatU64(value: u64, out: []u8) []const u8 {
    var tmp: [24]u8 = undefined;
    var n = value;
    var len: usize = 0;
    if (n == 0) {
        if (out.len == 0) return "";
        out[0] = '0';
        return out[0..1];
    }
    while (n != 0 and len < tmp.len) : (len += 1) {
        tmp[len] = @intCast('0' + (n % 10));
        n /= 10;
    }
    const count = @min(len, out.len);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        out[i] = tmp[len - 1 - i];
    }
    return out[0..count];
}

fn parseU64Decimal(value: []const u8) ?u64 {
    if (value.len == 0) return null;
    var out: u64 = 0;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return null;
        const digit: u64 = @intCast(ch - '0');
        if (out > (@as(u64, 0xFFFF_FFFF_FFFF_FFFF) - digit) / 10) return null;
        out = out * 10 + digit;
    }
    return out;
}

fn equalsBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

const ParsedCommand = struct {
    name: []const u8,
    args: []const u8,
};

const TwoArgs = struct {
    first: []const u8,
    second: []const u8,
};

const LineRange = struct {
    start: usize,
    len: usize,
};

const ResolvedProgram = struct {
    path: []const u8,
    class_id: i32,
};

const RedirectMode = enum {
    stdout_truncate,
    stdout_append,
    stdin,
};

const RedirectCommand = struct {
    command: []const u8,
    target: []const u8,
    mode: RedirectMode,
};

fn splitCommand(cmd: []const u8) ParsedCommand {
    const split = firstSpace(cmd) orelse return .{ .name = cmd, .args = "" };
    return .{
        .name = trim(cmd[0..split]),
        .args = trim(cmd[split + 1 ..]),
    };
}

fn parseTwoArgs(arg: []const u8, first_out: []u8, second_out: []u8) ?TwoArgs {
    var pos: usize = 0;
    const first = nextToken(arg, &pos) orelse return null;
    const second = nextToken(arg, &pos) orelse return null;
    if (nextToken(arg, &pos) != null) return null;
    if (first.len > first_out.len or second.len > second_out.len) return null;
    @memcpy(first_out[0..first.len], first);
    @memcpy(second_out[0..second.len], second);
    return .{ .first = first_out[0..first.len], .second = second_out[0..second.len] };
}

fn nextToken(s: []const u8, pos: *usize) ?[]const u8 {
    while (pos.* < s.len and (s[pos.*] == ' ' or s[pos.*] == '\t')) : (pos.* += 1) {}
    if (pos.* >= s.len) return null;
    const start = pos.*;
    while (pos.* < s.len and s[pos.*] != ' ' and s[pos.*] != '\t') : (pos.* += 1) {}
    return s[start..pos.*];
}

fn firstSpace(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == ' ' or s[i] == '\t') return i;
    }
    return null;
}

fn containsStreamSyntax(s: []const u8) bool {
    for (s) |c| {
        if (c == '>' or c == '<' or c == '|') return true;
    }
    return false;
}

fn hasWildcard(s: []const u8) bool {
    for (s) |c| {
        if (c == '*' or c == '?') return true;
    }
    return false;
}

fn hasSwitch(s: []const u8) bool {
    var pos: usize = 0;
    while (nextToken(s, &pos)) |token| {
        if (token.len > 1 and token[0] == '/') return true;
    }
    return false;
}

fn isHelpSwitch(args: []const u8) bool {
    return args.len == 2 and args[0] == '/' and args[1] == '?';
}

fn hasSelftestSwitch(s: []const u8) bool {
    var pos: usize = 0;
    while (nextToken(s, &pos)) |token| {
        if (equalsIgnoreCase(token, "/SELFTEST") or equalsIgnoreCase(token, "--SELFTEST")) return true;
    }
    return false;
}

fn hasConsoleUtilitySwitch(s: []const u8) bool {
    var pos: usize = 0;
    while (nextToken(s, &pos)) |token| {
        if (equalsIgnoreCase(token, "/CONSOLE") or equalsIgnoreCase(token, "--CONSOLE") or
            equalsIgnoreCase(token, "/EXPORT") or equalsIgnoreCase(token, "--EXPORT") or
            equalsIgnoreCase(token, "/RDPTRACE") or equalsIgnoreCase(token, "--RDPTRACE")) return true;
    }
    return false;
}

fn mentionsDevice(s: []const u8) bool {
    var pos: usize = 0;
    while (nextToken(s, &pos)) |token| {
        const name = stripPathAndExtension(token);
        if (equalsIgnoreCase(name, "CON") or equalsIgnoreCase(name, "NUL") or equalsIgnoreCase(name, "PRN") or
            equalsIgnoreCase(name, "AUX") or equalsIgnoreCase(name, "COM1") or equalsIgnoreCase(name, "LPT1"))
        {
            return true;
        }
    }
    return false;
}

fn stripPathAndExtension(token: []const u8) []const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (i < token.len) : (i += 1) {
        if (token[i] == '\\' or token[i] == '/' or token[i] == ':') start = i + 1;
    }
    var end = token.len;
    i = start;
    while (i < token.len) : (i += 1) {
        if (token[i] == '.') {
            end = i;
            break;
        }
    }
    return token[start..end];
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) {
        if (s[i] != prefix[i]) return false;
    }
    return true;
}

fn copyZ(out: [:0]u8, text: []const u8) ?[*:0]const u8 {
    if (text.len >= out.len) return null;
    @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return @ptrCast(out.ptr);
}

fn spanZSlice(buf: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buf.len and buf[len] != 0) : (len += 1) {}
    return buf[0..len];
}

fn baseName(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '\\' or path[i - 1] == '/') return path[i..];
    }
    return path;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - ('a' - 'A');
    return c;
}
