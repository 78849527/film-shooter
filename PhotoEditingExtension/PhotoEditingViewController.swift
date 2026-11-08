import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Invoked by the system Photos editor. This controller never changes the
/// source asset directly; Photos owns the transaction and provides the output URL.
@MainActor
final class PhotoEditingViewController: UIViewController, PHContentEditingController {
    private let model = PhotoEditingModel()
    private var host: UIHostingController<PhotoEditingScreen>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black

        let controller = UIHostingController(rootView: PhotoEditingScreen(model: model))
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.backgroundColor = .clear
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        controller.didMove(toParent: self)
        host = controller
    }

    func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool {
        PhotoEditingModel.savedRecipe(from: adjustmentData) != nil
    }

    func startContentEditing(with contentEditingInput: PHContentEditingInput, placeholderImage: UIImage) {
        // When canHandle is true, Photos supplies the original pixels, and
        // saved adjustment data restores the prior FilmShooter recipe.
        model.begin(input: contentEditingInput, placeholder: placeholderImage)
    }

    var shouldShowCancelConfirmation: Bool { model.hasChanges }

    func cancelContentEditing() {
        model.cancel()
    }

    private var finishDelivered = false
    private var finishTask: Task<Void, Never>?
    private var finishWatchdog: Task<Void, Never>?

    func finishContentEditing(completionHandler: @escaping (PHContentEditingOutput?) -> Void) {
        // One completion per Photos save request, even if GPU work stalls.
        guard !finishDelivered, finishTask == nil else { return }

        finishWatchdog = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch { return }
            guard let self, !self.finishDelivered else { return }
            self.finishDelivered = true
            self.model.error = "导出超时，未修改原照片。请尝试较小的图片。"
            self.model.cancel()
            completionHandler(nil)
        }

        finishTask = Task { [weak self] in
            guard let self else {
                completionHandler(nil)
                return
            }
            let output: PHContentEditingOutput?
            do {
                output = try await self.model.finish()
            } catch {
                self.model.error = "无法保存胶片效果：\(error.localizedDescription)"
                output = nil
            }
            guard !self.finishDelivered else { return }
            self.finishDelivered = true
            self.finishWatchdog?.cancel()
            completionHandler(output)
        }
    }
}
