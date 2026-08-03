// Copyright © 2015 Venture Media Labs. All rights reserved.
//
// This file is part of HDF5Kit. The full HDF5Kit copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

#if SWIFT_PACKAGE
    import CHDF5
#endif

open class HDF5Object {
    public internal(set) var id: hid_t = -1

    init(id: hid_t) {
        precondition(id >= 0, "HDF5Object ID needs to be non-negative")
        self.id = id
    }

    deinit {
        let status = H5Oclose(id)
        assert(status >= 0, "Failed to close HDF5Object")
    }

    public var file: HDF5File {
        let fileID = H5Iget_file_id(id)
        return HDF5File(id: fileID)
    }

    open var name: String {
        let count = H5Iget_name(id, nil, 0)
        if count <= 0 {
            return ""
        }

        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: count + 1)
        H5Iget_name(id, pointer, count + 1)
        return String(utf8String: pointer)!
    }
}

public func == (lhs: HDF5Object, rhs: HDF5Object) -> Bool {
    return lhs.id == rhs.id
}
