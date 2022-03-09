const std = @import("std");
const log = std.log;
const mem = std.mem;
const os = std.os;

const posix_spawnattr_t = *opaque {};
const posix_spawn_file_actions_t = *opaque {};
extern "c" fn posix_spawnattr_init(attr: *posix_spawnattr_t) c_int;
extern "c" fn posix_spawnattr_destroy(attr: *posix_spawnattr_t) void;
extern "c" fn posix_spawnattr_setflags(attr: *posix_spawnattr_t, flags: c_short) c_int;
extern "c" fn posix_spawn_file_actions_init(actions: *posix_spawn_file_actions_t) c_int;
extern "c" fn posix_spawn_file_actions_destroy(actions: *posix_spawn_file_actions_t) void;
extern "c" fn posix_spawnp(
    pid: *os.pid_t,
    path: [*:0]const u8,
    actions: ?*const posix_spawn_file_actions_t,
    attr: *const posix_spawnattr_t,
    argv: [*][*:0]const u8,
    env: [*][*:0]const u8,
) c_int;

const POSIX_SPAWN_RESETIDS: c_int = 0x0001;
const POSIX_SPAWN_SETPGROUP: c_int = 0x0002;
const POSIX_SPAWN_SETSIGDEF: c_int = 0x0004;
const POSIX_SPAWN_SETSIGMASK: c_int = 0x0008;
const POSIX_SPAWN_SETEXEC: c_int = 0x0040;
const POSIX_SPAWN_START_SUSPENDED: c_int = 0x0080;
const _POSIX_SPAWN_DISABLE_ASLR: c_int = 0x0100;
const POSIX_SPAWN_SETSID: c_int = 0x0400;
const _POSIX_SPAWN_RESLIDE: c_int = 0x0800;
const POSIX_SPAWN_CLOEXEC_DEFAULT: c_int = 0x4000;

const MACH_MSG_TYPE_PORT_NAME = 15;

const kern_return_t = c_int;
const __darwin_natural_t = c_uint;
const __darwin_mach_port_name_t = __darwin_natural_t;
const __darwin_mach_port_t = __darwin_mach_port_name_t;
const natural_t = __darwin_natural_t;
const mach_port_name_t = natural_t;
const mach_port_t = __darwin_mach_port_t;

extern "c" var mach_task_self_: mach_port_t;
extern "c" fn task_for_pid(target_tport: mach_port_name_t, pid: os.pid_t, t: *mach_port_name_t) kern_return_t;

fn mach_task_self() callconv(.C) mach_port_t {
    return mach_task_self_;
}

const vm_map_t = mach_port_t;
const mach_vm_address_t = usize;
const vm_offset_t = usize;
const mach_msg_type_number_t = natural_t;
extern "c" fn mach_vm_write(
    target_task: vm_map_t,
    address: mach_vm_address_t,
    data: vm_offset_t,
    data_cnt: mach_msg_type_number_t,
) kern_return_t;

const errno = std.c.getErrno;

var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_alloc.allocator();

pub fn main() anyerror!void {
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const exe_path = args[1];
    const aslr_off = if (args.len == 3 and mem.eql(u8, args[2], "--aslr-off")) true else false;

    log.info("Init...", .{});
    var attr: posix_spawnattr_t = undefined;
    var res = posix_spawnattr_init(&attr);
    defer posix_spawnattr_destroy(&attr);
    log.info("attr = {*}", .{attr});

    switch (errno(res)) {
        .SUCCESS => {},
        .NOMEM => return error.NoMemory,
        .INVAL => return error.InvalidValue,
        else => unreachable,
    }

    log.info("Setting flags...", .{});
    var flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
    if (aslr_off) {
        flags |= _POSIX_SPAWN_DISABLE_ASLR;
    }

    res = posix_spawnattr_setflags(&attr, @intCast(c_short, flags));

    switch (errno(res)) {
        .SUCCESS => {},
        .INVAL => return error.InvalidValue,
        else => unreachable,
    }

    // const path: [:0]const u8 = "./hello";
    const argv: [][*:0]const u8 = &.{};
    const env: [][*:0]const u8 = &.{};
    var pid: os.pid_t = -1;
    res = posix_spawnp(&pid, exe_path, null, &attr, argv.ptr, env.ptr);

    switch (errno(res)) {
        .SUCCESS => {},
        else => return error.SpawnpFailed,
    }

    log.info("pid = {d}", .{pid});

    const stderr = std.io.getStdErr().writer();
    const stdin = std.io.getStdIn().reader();
    var repl_buf: [4096]u8 = undefined;

    while (true) {
        try stderr.print("\nOverwrite address 0x100052030, thus stopping the process?", .{});
        if (stdin.readUntilDelimiterOrEof(&repl_buf, '\n') catch |err| {
            try stderr.print("\nunable to parse command: {s}\n", .{@errorName(err)});
            continue;
        }) |_| {
            var port: mach_port_name_t = undefined;
            var kern_res = task_for_pid(mach_task_self(), pid, &port);
            if (kern_res != 0) {
                return error.TaskForPidFailed;
            }
            log.info("kern_res = {}, port = {}", .{ kern_res, port });

            const address: mach_vm_address_t = 0x100052030;
            const swap_addr: u64 = 0x100001082;
            var buf: [@sizeOf(u64)]u8 = undefined;
            mem.writeIntLittle(u64, &buf, swap_addr);
            kern_res = mach_vm_write(port, address, @ptrToInt(&buf), buf.len);
            if (kern_res != 0) {
                return error.MachVMWriteFailed;
            }
            log.info("kern_res = {}", .{kern_res});

            const pid_res = os.waitpid(pid, 0);
            log.info("pid_res = {}", .{pid_res});

            break;
        }
    }
}
