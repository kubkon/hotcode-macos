# hotcode-macos

Hotcode reloading playground for Zig + macOS.

Some preliminary results:

Given input Zig file `hello.zig`

```zig
fn ok() bool {
    return true;
}

export fn fail() bool {
    return false;
}

pub fn main() void {
    while (ok()) {}
}
```

We compile it with self-hosted (stage2) compiler

```
$ zig-stage2 build-exe hello.zig -target x86_64-macos
```

Then, we spawn the executable using `posix_spawnp` with ASLR off.

```
$ sudo zig build run -- ./hello --aslr-off
Password:
info: Init...
info: attr = posix_spawnattr_t@600003130000
info: Setting flags...
info: pid = 87803

Overwrite address 0x100052030, thus stopping the process?
```

The program is running under some assigned PID in an endless loop, until
we hit Enter and overwrite a cell in GOT at a hard-coded address of `0x100052030`
to point to function `fn fail()` which will terminate the loop in `hello` and thus
terminate the process. We monitor the output status exit code too.

```
$ sudo zig build run -- ./hello --aslr-off
Password:
info: Init...
info: attr = posix_spawnattr_t@600003130000
info: Setting flags...
info: pid = 87803

Overwrite address 0x100052030, thus stopping the process?
info: kern_res = 0, port = 4867
info: kern_res = 0
info: pid_res = WaitPidResult{ .pid = 87803, .status = 0 }
```
