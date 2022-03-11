const std = @import("std");
const log = std.log;
const mem = std.mem;
const os = std.os;
const c = std.c;

const integer_t = c_int;
const task_flavor_t = c.natural_t;
const task_info_t = *integer_t;
const task_name_t = c.mach_port_name_t;
const vm_size_t = c.mach_vm_size_t;

const TASK_VM_INFO = 22;
const TASK_VM_INFO_COUNT: c.mach_msg_type_number_t = @sizeOf(task_vm_info_data_t) / @sizeOf(c.natural_t);

const task_vm_info = extern struct {
    // virtual memory size (bytes)
    virtual_size: c.mach_vm_size_t,
    // number of memory regions
    region_count: integer_t,
    page_size: integer_t,
    // resident memory size (bytes)
    resident_size: c.mach_vm_size_t,
    // peak resident size (bytes)
    resident_size_peak: c.mach_vm_size_t,

    device: c.mach_vm_size_t,
    device_peak: c.mach_vm_size_t,
    internal: c.mach_vm_size_t,
    internal_peak: c.mach_vm_size_t,
    external: c.mach_vm_size_t,
    external_peak: c.mach_vm_size_t,
    reusable: c.mach_vm_size_t,
    reusable_peak: c.mach_vm_size_t,
    purgeable_volatile_pmap: c.mach_vm_size_t,
    purgeable_volatile_resident: c.mach_vm_size_t,
    purgeable_volatile_virtual: c.mach_vm_size_t,
    compressed: c.mach_vm_size_t,
    compressed_peak: c.mach_vm_size_t,
    compressed_lifetime: c.mach_vm_size_t,

    // added for rev1
    phys_footprint: c.mach_vm_size_t,

    // added for rev2
    min_address: c.mach_vm_address_t,
    max_address: c.mach_vm_address_t,

    // added for rev3
    ledger_phys_footprint_peak: i64,
    ledger_purgeable_nonvolatile: i64,
    ledger_purgeable_novolatile_compressed: i64,
    ledger_purgeable_volatile: i64,
    ledger_purgeable_volatile_compressed: i64,
    ledger_tag_network_nonvolatile: i64,
    ledger_tag_network_nonvolatile_compressed: i64,
    ledger_tag_network_volatile: i64,
    ledger_tag_network_volatile_compressed: i64,
    ledger_tag_media_footprint: i64,
    ledger_tag_media_footprint_compressed: i64,
    ledger_tag_media_nofootprint: i64,
    ledger_tag_media_nofootprint_compressed: i64,
    ledger_tag_graphics_footprint: i64,
    ledger_tag_graphics_footprint_compressed: i64,
    ledger_tag_graphics_nofootprint: i64,
    ledger_tag_graphics_nofootprint_compressed: i64,
    ledger_tag_neural_footprint: i64,
    ledger_tag_neural_footprint_compressed: i64,
    ledger_tag_neural_nofootprint: i64,
    ledger_tag_neural_nofootprint_compressed: i64,

    // added for rev4
    limit_bytes_remaining: u64,

    // added for rev5
    decompressions: integer_t,
};
const task_vm_info_data_t = task_vm_info;

extern "c" fn task_info(
    target_task: task_name_t,
    flavor: task_flavor_t,
    task_info_out: task_info_t,
    task_info_outCnt: *c.mach_msg_type_number_t,
) c.kern_return_t;
extern "c" fn _host_page_size(task: c.mach_port_t, size: *vm_size_t) c.kern_return_t;

const errno = c.getErrno;

var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_alloc.allocator();

pub fn main() anyerror!void {
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const exe_path = args[1];
    const aslr_off = if (args.len == 3 and mem.eql(u8, args[2], "--aslr-off")) true else false;

    log.info("Init...", .{});
    var attr: c.posix_spawnattr_t = undefined;
    var res = c.posix_spawnattr_init(&attr);
    defer c.posix_spawnattr_destroy(&attr);
    log.info("attr = {*}", .{attr});

    switch (errno(res)) {
        .SUCCESS => {},
        .NOMEM => return error.NoMemory,
        .INVAL => return error.InvalidValue,
        else => unreachable,
    }

    log.info("Setting flags...", .{});
    var flags = c.POSIX_SPAWN_SETSIGDEF | c.POSIX_SPAWN_SETSIGMASK;
    if (aslr_off) {
        flags |= c._POSIX_SPAWN_DISABLE_ASLR;
    }

    res = c.posix_spawnattr_setflags(&attr, @intCast(c_short, flags));

    switch (errno(res)) {
        .SUCCESS => {},
        .INVAL => return error.InvalidValue,
        else => unreachable,
    }

    // const path: [:0]const u8 = "./hello";
    const argv: [][*:0]const u8 = &.{};
    const env: [][*:0]const u8 = &.{};
    var pid: os.pid_t = -1;
    res = c.posix_spawnp(&pid, exe_path, null, &attr, argv.ptr, env.ptr);

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
            var port: c.mach_port_name_t = undefined;
            var kern_res = c.task_for_pid(c.mach_task_self(), pid, &port);
            if (kern_res != 0) {
                return error.TaskForPidFailed;
            }
            log.info("kern_res = {}, port = {}", .{ kern_res, port });

            const page_size = try pageSize(port);
            log.info("page_size = {}", .{page_size});

            const address: c.mach_vm_address_t = 0x100052030;
            // var buf: u64 = undefined;
            // var count: c_uint = 0;

            // kern_res = c.mach_vm_read(port, address, 8, &buf, &count);
            // if (kern_res == 0) {
            //     log.warn("{x}, count = {}", .{ buf, count });
            // } else {
            //     return error.MachVMReadFailed;
            // }

            const swap_addr: u64 = 0x100001088;
            var tbuf: [8]u8 = undefined;
            mem.writeIntLittle(u64, &tbuf, swap_addr);
            kern_res = c.mach_vm_write(port, address, @ptrToInt(&tbuf), 8);
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

// fn vmRead(task: c.mach_port_name_t, address: u64, buf: []u8, count: usize) ![]u8 {
//     var total_read: usize = 0;
//     var curr_addr = address;

//     while (total_read < count) {

//     }
// }

// fn maxBytesLeftInPage(task: c.mach_port_name_t, address: u64, count: usize) usize {

// }

fn pageSize(task: c.mach_port_name_t) !usize {
    if (task != 0) {
        var info_count = TASK_VM_INFO_COUNT;
        var vm_info: task_vm_info_data_t = undefined;
        const kern_res = task_info(task, TASK_VM_INFO, @ptrCast(task_info_t, &vm_info), &info_count);
        if (kern_res != 0) {
            log.err("task_info failed with error: {d}", .{kern_res});
        } else {
            log.info("page_size = {x}", .{vm_info.page_size});
            return @intCast(usize, vm_info.page_size);
        }
    }
    var page_size: vm_size_t = undefined;
    const kern_res = _host_page_size(c.mach_host_self(), &page_size);
    if (kern_res != 0) {
        log.err("_host_page_size failed with error: {d}", .{kern_res});
    }
    return page_size;
}
