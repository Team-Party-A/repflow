import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum MealPhoto {
    static func encode(_ original: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                ] as CFDictionary)
        else { throw NutritionError.invalidPhoto }
        let result = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                result, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw NutritionError.invalidPhoto }
        // 仅复制解码并旋转后的像素。原文件的 EXIF、GPS 和缩略图不进入新 JPEG。
        CGImageDestinationAddImage(
            dest, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(dest), result.length <= 4 * 1024 * 1024 else {
            throw NutritionError.invalidPhoto
        }
        return result as Data
    }

    static func encode(_ original: UIImage) throws -> Data {
        guard let data = original.jpegData(compressionQuality: 0.9) else {
            throw NutritionError.invalidPhoto
        }
        return try encode(data)
    }
}

struct MealCamera: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
        UINavigationControllerDelegate
    {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            completion(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
    }
}
