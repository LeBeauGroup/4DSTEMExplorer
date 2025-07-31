struct Dimensions: Codable {
    var TagGroup0: Int?
}

struct Taggroup0: Codable {
    var Origin: Float?
    var Units: String?
    var Scale: Float?
}

struct CalibrationAxis: Codable {
    var TagGroup0: Taggroup0?
}

struct CalibrationSet: Codable {
    var Dimension: CalibrationAxis?
    var DisplayCalibratedUnits: Bool?
    var Brightness: CalibrationAxis?
}

struct ImageData: Codable {
    var Offset: Int?
    var Size: Int?
    var DataType: Int?
}

struct Uniqueid: Codable {
    let TagGroup0: Int
}

struct Calibration: Codable {
    var Dose_Rate: Float?
}

struct Dose_rate: Codable {
    var Lower_Threshold: Float?
    var Sensor_Count_Upper_Threshold: Float?
    var Upper_Threshold: Float?
    var Scaling_Factor: Float?
    var Gain_Factor: Float?
    var Sensor_Count_Lower_Threshold: Float?
    var Calibration: Calibration?
    var Calibration_Method: Int?
}

struct AcquisitionInfo: Codable {
    var Number_of_frames: Int?
    var Exposure_s: Float?
}

struct Diffraction: Codable {
    var Acquisition: AcquisitionInfo?
}

struct Gms_version: Codable {
    var Created: String
    var Saved: String?
}

struct Imagetags: Codable {
    var Calibration: Calibration?
    var Diffraction: Diffraction?
    var GMS_Version: Gms_version?
}

struct Imageentry: Codable {
    var ImageData: ImageData?
    var Name: String?
    var UniqueID: Uniqueid?
    var ImageTags: Imagetags?
}
