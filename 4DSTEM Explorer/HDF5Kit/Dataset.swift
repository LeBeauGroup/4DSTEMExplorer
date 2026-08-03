// Copyright © 2015 Venture Media Labs. All rights reserved.
//
// This file is part of HDF5Kit. The full HDF5Kit copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

#if SWIFT_PACKAGE
    import CHDF5
#endif

open class HDF5Dataset: HDF5Object {
    /// The address in the file of the dataset or `nil` if the offset is undefined. That address is expressed as the offset in bytes from the beginning of the file.
    public var offset: Int? {
        let offset = H5Dget_offset(id)
        guard offset != UInt64(bitPattern: Int64(-1)) else {
            return nil
        }
        return Int(offset)
    }

    public var space: HDF5Dataspace {
        return HDF5Dataspace(id: H5Dget_space(id))
    }

    public var type: HDF5Datatype {
        return HDF5Datatype(id: H5Dget_type(id))
    }

    public var extent: [Int] {
        get {
            return space.dims
        }
        set {
            let array = newValue.map({ hsize_t(bitPattern: hssize_t($0)) })
            array.withUnsafeBufferPointer { (pointer) -> Void in
                H5Dset_extent(id, pointer.baseAddress)
            }
        }
    }

    /// Retrieves the size of chunks for the raw data of a chunked layout HDF5Dataset, or `nil` if the HDF5Dataset's layout is not chunked
    public var chunkSize: [Int]? {
        let plistId = H5Dget_create_plist(id)
        if H5Pget_layout(plistId) != H5D_CHUNKED {
            return nil
        }

        let rank = space.dims.count
        var chunkSize = [hsize_t](repeating: 0, count: rank)
        chunkSize.withUnsafeMutableBufferPointer { (pointer: inout UnsafeMutableBufferPointer<hsize_t>) -> Void in
            H5Pget_chunk(plistId, Int32(rank), pointer.baseAddress)
        }
        return chunkSize.map({ Int(hssize_t(bitPattern: $0)) })
    }

    /// Read data using an optional memory HDF5Dataspace and an optional file HDF5Dataspace
    ///
    /// - precondition: The `selectionSize` of the memory HDF5Dataspace is the same as for the file HDF5Dataspace and there is enough memory available for it
    open func read(into pointer: UnsafeMutableRawPointer, type: HDF5NativeType, memSpace: HDF5Dataspace? = nil, fileSpace: HDF5Dataspace? = nil) throws {
        let status = H5Dread(id, type.rawValue, memSpace?.id ?? 0, fileSpace?.id ?? 0, 0, pointer)
        if status < 0 {
            throw HDF5KitError.ioError
        }
    }

    /// Write data using an optional memory HDF5Dataspace and an optional file HDF5Dataspace
    ///
    /// - precondition: The `selectionSize` of the memory HDF5Dataspace is the same as for the file HDF5Dataspace
    open func write(from pointer: UnsafeRawPointer, type: HDF5NativeType, memSpace: HDF5Dataspace? = nil, fileSpace: HDF5Dataspace? = nil) throws {
        let status = H5Dwrite(id, type.rawValue, memSpace?.id ?? 0, fileSpace?.id ?? 0, 0, pointer);
        if status < 0 {
            throw HDF5KitError.ioError
        }
    }
}


// MARK: HDF5GroupType extension for HDF5Dataset

extension HDF5GroupType {
    /// Create a HDF5Dataset
    public func createDataset(_ name: String, datatype: HDF5Datatype, dataspace: HDF5Dataspace) -> HDF5Dataset {
        let datasetID = name.withCString{ name in
            return H5Dcreate2(id, name, datatype.id, dataspace.id, 0, 0, 0)
        }
        return HDF5Dataset(id: datasetID)
    }

    /// Create a chunked HDF5Dataset
    public func createDataset(_ name: String, datatype: HDF5Datatype, dataspace: HDF5Dataspace, chunkDimensions: [Int]) -> HDF5Dataset? {
        precondition(dataspace.dims.count == chunkDimensions.count)

        let plist = H5Pcreate(H5P_CLS_DATASET_CREATE_ID_g)
        H5Pset_char_encoding(plist, H5T_CSET_UTF8)
        let chunkDimensions64 = chunkDimensions.map({ hsize_t(bitPattern: hssize_t($0)) })
        chunkDimensions64.withUnsafeBufferPointer { (pointer) -> Void in
            H5Pset_chunk(plist, Int32(chunkDimensions.count), pointer.baseAddress)
        }
        defer {
            H5Pclose(plist)
        }

        let datasetID = name.withCString{ name in
            return H5Dcreate2(id, name, datatype.id, dataspace.id, 0, plist, 0)
        }
        return HDF5Dataset(id: datasetID)
    }

    /// Open an existing HDF5Dataset
    public func openDataset(_ name: String) -> HDF5Dataset? {
        let datasetID = name.withCString{ name in
            return H5Dopen2(id, name, 0)
        }
        guard datasetID >= 0 else {
            return nil
        }
        return HDF5Dataset(id: datasetID)
    }
}
