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
