# Vendored HDF5Kit

Swift wrapper for the HDF5 C library, copied from
[trueb2/HDF5Kit](https://github.com/trueb2/HDF5Kit) (MIT, see `LICENSE`).
The exact revision is recorded in `VENDORED_REVISION.txt`.

## Why vendored rather than a package dependency

HDF5Kit resolves its C API through `trueb2/CHDF5`, whose `module.modulemap`
hardcodes `/usr/local/include/H5*.h`. Homebrew on Apple silicon installs to
`/opt/homebrew`, so the headers are never found and the build fails. Fixing it
through SwiftPM would mean hosting forks of both repositories, because
HDF5Kit's `Package.swift` hardcodes the CHDF5 URL.

Compiling the sources directly into the app target avoids the module map
entirely: `HDF5Kit-Bridging-Header.h` imports `<hdf5.h>` and the target's
header/library search paths point at the Homebrew keg. HDF5Kit has had no
commits since 2020, so pinning it costs nothing.

## Requirement

    brew install hdf5

The target expects headers at `/opt/homebrew/opt/hdf5/include` and the library
at `/opt/homebrew/opt/hdf5/lib`.

## Local changes

One, applied mechanically so it is easy to re-apply after a re-fetch:

* `Error` renamed to `HDF5KitError` (`Error.swift` plus its `throw` sites).
  HDF5Kit declares a top-level `public enum Error`. Inside its own module that
  is harmless, but compiled into the app target it shadows `Swift.Error`
  everywhere — `catch { ... error as? Error }` would silently become a downcast
  to HDF5Kit's enum rather than a test against the protocol.

`Group.objectNames()` is also deliberately **not** used: it calls
`H5Gget_num_objs`/`H5Gget_objname_by_idx`, HDF5 1.6 APIs deprecated since 1.8
that a build without deprecated symbols will not export. `EMDReader` walks
groups with the modern `H5Lget_name_by_idx` instead.
