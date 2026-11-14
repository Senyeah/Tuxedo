# Venus spike (A11)

Throw-away probes for the question in [LINUX-PLAN-10](../../../LINUX-PLAN-10-accelerated-graphics.md), task A11: could Tuxedo give a Linux guest Vulkan through Venus? Nothing here is in the default build. The result is the A11 entry in the findings log of LINUX-PLAN-09.

| File | What it shows |
|---|---|
| `window_probe.m`, `window_guest.S`, `build.sh` | Steps 1 and 2: a 256 MB RAM region over a `PROT_NONE` reservation, filled with `vm_remap` or `mmap` of a shm fd, used by guest code through the JIT and by a Metal buffer |
| `server_probe.c` | Step 4: virglrenderer built with Venus and `render-server-mode=thread` starts its render server inside the process |
| `vkprobe.c` | Step 4: what extensions, memory types and features a host Vulkan (MoltenVK) offers Venus |

```sh
tools/gfx/venus-spike/build.sh "$OUT"   # builds $OUT/window_probe
"$OUT/window_probe"                     # all steps; --hole checks a buffer over a PROT_NONE hole
```

The Venus build of virglrenderer needs no source change. Configure the pinned tree (`tools/gfx/versions.env`) with the options of `build_virgl` in `tools/gfx/build-deps.sh`, but with `-Dvenus=true -Dvulkan-dload=true -Drender-server-mode=thread -Drender-server-worker=thread` and the Vulkan headers of a MoltenVK release in the include path. The library result is 4.4 MB against 1.1 MB.
