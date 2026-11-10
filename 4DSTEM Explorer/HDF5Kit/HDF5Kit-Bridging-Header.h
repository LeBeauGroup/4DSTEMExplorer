//
//  HDF5Kit-Bridging-Header.h
//  4DSTEM Explorer
//
//  Exposes the HDF5 C API to Swift.
//
//  The vendored HDF5Kit sources guard their `import CHDF5` behind
//  `#if SWIFT_PACKAGE`. Compiled into the app target rather than through
//  SwiftPM that symbol is undefined, so the C API has to arrive some other
//  way — this bridging header. It also sidesteps CHDF5's module map, which
//  hardcodes /usr/local/include and therefore cannot find an arm64 Homebrew
//  install at /opt/homebrew.
//
//  Requires: brew install hdf5
//

#import <hdf5.h>

//  MARK: - Shims for things Swift cannot reach
//
//  Two pieces of the C API are spelled differently depending on which libhdf5
//  is installed, and in both cases the difference is invisible to Swift: the
//  Clang importer only imports a macro that is a plain constant, and skips one
//  that expands to a comma expression or aliases a function. Wrapping each in a
//  `static inline` moves the decision into the preprocessor, where it belongs,
//  and leaves Swift one name that works on 1.10.2 through 2.x.
//
//  Without these the app builds only against the exact HDF5 it was written
//  for — which is how it came to be broken against Homebrew's 1.14.3.

/// `H5F_ACC_RDONLY`, which Swift cannot see on HDF5 < 2.0.
///
/// Before 2.0 the flag is `(H5CHECK H5OPEN 0x0000u)`, which outside a private
/// include expands to the comma expression `(H5check(), H5open(), 0x0000u)` —
/// not a constant, so the importer drops it. 2.0 reduced it to `(0x0000u)` and
/// dropped `H5CHECK`/`H5OPEN` altogether. Going through C keeps the older
/// header's side effects: `H5open()` initialises the library and `H5check()`
/// asserts that these headers match the library actually linked.
static inline unsigned hdf5_acc_rdonly(void) { return H5F_ACC_RDONLY; }

/// Reads one raw, still-filtered chunk into `buf`, which holds `capacity` bytes.
///
/// HDF5 2.0 added a `buf_size` parameter, renamed the old four-argument form to
/// the deprecated `H5Dread_chunk1`, and made `H5Dread_chunk` a macro for the
/// new `H5Dread_chunk2`. A Swift call therefore has no portable spelling: the
/// macro does not import, `H5Dread_chunk1` does not exist before 2.0, and
/// `H5Dread_chunk2` does not either.
///
/// `H5Dread_chunk2` is preferred where it exists. It is the form that is not
/// deprecated, and `capacity` makes it refuse to overrun the buffer rather
/// than writing however many bytes the chunk turns out to hold.
static inline herr_t hdf5_read_chunk(hid_t dataset, hid_t dxpl,
                                     const hsize_t *offset, uint32_t *filters,
                                     void *buf, size_t capacity) {
#if H5_VERSION_GE(2, 0, 0)
    size_t size = capacity;
    return H5Dread_chunk2(dataset, dxpl, offset, filters, buf, &size);
#else
    (void)capacity;
    return H5Dread_chunk(dataset, dxpl, offset, filters, buf);
#endif
}
