# hotcode-macos

Hotcode reloading playground for Zig + macOS.

Some preliminary results:

Given input Zig file `hello.zig`

```zig
extern "c" fn write(usize, usize, usize) c_int;

fn foo() void {
    _ = write(1, @ptrToInt("Hello"), 5);
}

pub fn main() void {
    assertAslr(@ptrToInt(&foo));
}

fn assertAslr(ptr: usize) void {
    if (ptr != 0x1000010D7) unreachable;
}
```

We compile it with self-hosted (stage2) compiler

```
$ zig-stage2 build-exe hello.zig -target x86_64-macos
```

Then, we spawn the executable using `posix_spawnp` first with ASLR on

```
$ zig build run -- ./hello
info: Init...
info: attr = posix_spawnattr_t@600001948000
info: Setting flags...
info: pid = 82148
info: pid_res = WaitPidResult{ .pid = 82148, .status = 5 }
```

And with ASLR off

```
$ zig build run -- ./hello --aslr-off
info: Init...
info: attr = posix_spawnattr_t@600000a9c000
info: Setting flags...
info: pid = 82159
info: pid_res = WaitPidResult{ .pid = 82159, .status = 0 }
```
