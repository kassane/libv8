solutions = [
  {
    "name": "v8",
    "url": "https://chromium.googlesource.com/v8/v8.git",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {
      # Test fixtures and platform SDKs that aren't needed to build the
      # monolithic library. Kept aligned with kuoruan/libv8 to avoid
      # pruning something V8's build actually requires (e.g. perfetto,
      # protobuf — do NOT add those here).
      "v8/test/benchmarks/data": None,
      "v8/test/mozilla/data": None,
      "v8/test/test262/data": None,
      "v8/test/test262/harness": None,
      "v8/test/wasm-js": None,
      "v8/testing/gmock": None,
      "v8/third_party/android_sdk": None,
      "v8/third_party/android_toolchain": None,
      "v8/third_party/catapult": None,
      "v8/third_party/colorama/src": None,
      "v8/third_party/fuchsia-sdk": None,
      "v8/third_party/qemu-linux-arm64": None,
      "v8/third_party/qemu-linux-x64": None,
      "v8/third_party/qemu-mac-arm64": None,
      "v8/third_party/qemu-mac-x64": None,
      "v8/tools/luci-go": None,
    },
  },
]
