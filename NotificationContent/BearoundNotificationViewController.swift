//
//  BearoundNotificationViewController.swift
//  BearoundSDKNotificationExtensions/Content
//
//  Notification Content Extension for Bearound rich push. Draws the cards of a
//  `bearound_rich` payload programmatically (no storyboard): one image, two side-by-side
//  cards or a paged carousel. PLAY is not drawn here: the Service Extension attaches the
//  video and the system player shows it on expand. Extension-safe: does not depend on the
//  core SDK.
//
//  Host usage (the whole NotificationViewController.swift of the host's content extension):
//
//      import BearoundSDKNotificationExtensions
//      class NotificationViewController: BearoundNotificationViewController {}
//
//  The extension's Info.plist declares `BearoundPushCategory.contentExtension` as
//  `UNNotificationExtensionCategory` and `UNNotificationExtensionUserInteractionEnabled = YES`
//  (without it card taps do nothing). Never `BEAROUND_PLAY`: claiming it would replace the
//  system video player with this view.
//

import UIKit
import UserNotifications
import UserNotificationsUI

open class BearoundNotificationViewController: UIViewController, UNNotificationContentExtension, UIScrollViewDelegate {
    private enum Layout { case single, twoImages, carousel }

    private static let spacing: CGFloat = 8
    /// Gap between an image and its caption.
    private static let captionGap: CGFloat = 4
    /// Two-image cards are uploaded at up to 1080x608.
    private static let twoImagesRatio: CGFloat = 608.0 / 1080.0
    private static let carouselRatio: CGFloat = 0.75
    private static let cardImageTimeout: TimeInterval = 15

    private let container = UIView()
    private var payload: RichPushPayload?
    private var layout: Layout?
    private var hasCaption = false
    private var singleRatio: CGFloat = 1
    private var attachmentImage: UIImage?
    private var imageViews: [UIImageView] = []
    /// Cards whose image is on screen. A card enters only after a successful load, so a
    /// failed fetch is retried the next time the card is shown.
    private var loaded = Set<Int>()
    private var downloads: [Int: BearoundBoundedDownload] = [:]
    /// Bumped on every render, so a fetch started for a previous notification is ignored.
    private var generation = 0
    private var singleAspect: NSLayoutConstraint?
    private var chevronCenter: NSLayoutConstraint?
    private weak var scrollView: UIScrollView?
    private weak var prevButton: UIButton?
    private weak var nextButton: UIButton?
    private var currentPage = 0
    /// The open hit of a card tap, held until it completes.
    private var openHitTask: URLSessionDataTask?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// URL schemes the containing app declares (`CFBundleURLTypes`). The app bundle is two
    /// directories up from this appex (`App.app/PlugIns/Ext.appex`).
    private lazy var hostSchemes: Set<String> = {
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return [] }
        return RichPush.declaredURLSchemes(infoDictionary: Bundle(url: appURL)?.infoDictionary)
    }()

    open override func viewDidLoad() {
        super.viewDidLoad()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    open func didReceive(_ notification: UNNotification) {
        render(notification.request.content)
    }

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayout(width: view.bounds.width)
        // Keep the carousel on its page when the width changes.
        if let scrollView, scrollView.bounds.width > 0, !scrollView.isDragging, !scrollView.isDecelerating {
            let x = CGFloat(currentPage) * scrollView.bounds.width
            if abs(scrollView.contentOffset.x - x) > 0.5 { scrollView.contentOffset = CGPoint(x: x, y: 0) }
        }
    }

    open override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        updateLayout(width: size.width)
    }

    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateLayout(width: view.bounds.width)
        }
    }

    // MARK: - Layout

    private var availableWidth: CGFloat {
        view.bounds.width > 0 ? view.bounds.width : 320
    }

    /// Caption height at the current Dynamic Type size (one line of `.footnote`).
    private var captionHeight: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traitCollection).lineHeight)
    }

    private func render(_ content: UNNotificationContent) {
        downloads.values.forEach { $0.cancel() }
        downloads = [:]
        generation += 1
        container.subviews.forEach { $0.removeFromSuperview() }
        imageViews = []
        loaded = []
        layout = nil
        hasCaption = false
        singleRatio = 1
        singleAspect = nil
        chevronCenter = nil
        currentPage = 0

        // PLAY belongs to the system video player; a host that still lists its category gets
        // an empty view here instead of a still cover.
        payload = RichPushPayload.parse(content.userInfo).flatMap { $0.format == .play ? nil : $0 }
        attachmentImage = Self.attachmentImage(in: content)
        guard let payload else {
            preferredContentSize = CGSize(width: availableWidth, height: 0)
            return
        }

        hasCaption = payload.cards.contains { $0.caption != nil }
        switch payload.format {
        case .image: buildSingle(payload)
        case .twoImages: buildTwoImages(payload)
        case .carousel: buildCarousel(payload)
        case .play: break
        }
        updateLayout(width: availableWidth)
    }

    /// Recomputes `preferredContentSize` and the pager position from the width and the
    /// caption's current Dynamic Type height. Called on render, layout, size and text-size
    /// changes; only writes when something moved.
    private func updateLayout(width: CGFloat) {
        guard let layout, width > 0 else { return }
        let caption = hasCaption ? captionHeight + Self.captionGap : 0
        let height: CGFloat
        switch layout {
        case .single:
            height = width * singleRatio + (hasCaption ? caption + Self.spacing : 0)
        case .twoImages:
            let cardWidth = (width - 3 * Self.spacing) / 2
            height = 2 * Self.spacing + cardWidth * Self.twoImagesRatio + caption
        case .carousel:
            let imageHeight = (width - 2 * Self.spacing) * Self.carouselRatio
            let center = Self.spacing + imageHeight / 2
            if let chevronCenter, abs(chevronCenter.constant - center) > 0.5 { chevronCenter.constant = center }
            height = 2 * Self.spacing + imageHeight + caption
        }
        let size = CGSize(width: width, height: ceil(height))
        if preferredContentSize != size { preferredContentSize = size }
    }

    private func buildSingle(_ payload: RichPushPayload) {
        layout = .single
        let card = makeCard(index: 0, caption: payload.cards[0].caption, ratio: nil)
        pin(card, insets: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
        loadImage(at: 0)
    }

    private func buildTwoImages(_ payload: RichPushPayload) {
        layout = .twoImages
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.spacing = Self.spacing
        for index in payload.cards.indices {
            stack.addArrangedSubview(makeCard(index: index, caption: payload.cards[index].caption, ratio: Self.twoImagesRatio))
        }
        let inset = Self.spacing
        pin(stack, insets: UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset))
        payload.cards.indices.forEach { loadImage(at: $0) }
    }

    private func buildCarousel(_ payload: RichPushPayload) {
        layout = .carousel
        let scroll = UIScrollView()
        scroll.isPagingEnabled = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.delegate = self
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        for index in payload.cards.indices {
            let page = UIView()
            let card = makeCard(index: index, caption: payload.cards[index].caption, ratio: Self.carouselRatio)
            card.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: page.topAnchor, constant: Self.spacing),
                card.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: Self.spacing),
                card.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -Self.spacing),
            ])
            stack.addArrangedSubview(page)
            page.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor).isActive = true
            page.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor).isActive = true
        }

        pin(scroll, insets: .zero)
        scrollView = scroll

        let prev = makePagerButton(symbol: "chevron.left.circle.fill", action: #selector(showPrevious))
        let next = makePagerButton(symbol: "chevron.right.circle.fill", action: #selector(showNext))
        // The constant (image center) is set by updateLayout for the current width.
        let center = prev.centerYAnchor.constraint(equalTo: container.topAnchor, constant: 0)
        NSLayoutConstraint.activate([
            prev.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.spacing * 2),
            next.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.spacing * 2),
            center,
            next.centerYAnchor.constraint(equalTo: prev.centerYAnchor),
        ])
        chevronCenter = center
        prevButton = prev
        nextButton = next

        updatePager()
        loadImage(at: 0)
    }

    /// Image view plus optional caption. `ratio` nil = the single-card layout, whose aspect
    /// follows the loaded image.
    private func makeCard(index: Int, caption: String?, ratio: CGFloat?) -> UIView {
        let card = UIView()
        card.tag = index
        card.isUserInteractionEnabled = true
        card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cardTapped(_:))))

        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground
        imageView.layer.cornerRadius = ratio == nil ? 0 : 8
        card.addSubview(imageView)
        imageViews.append(imageView)

        var constraints = [
            imageView.topAnchor.constraint(equalTo: card.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ]
        if let ratio {
            constraints.append(imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: ratio))
        } else {
            let aspect = imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 1)
            constraints.append(aspect)
            singleAspect = aspect
        }

        if let caption {
            // No fixed height: the label follows Dynamic Type, and updateLayout sizes the
            // notification from the same font's line height.
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.text = caption
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 1
            label.textColor = .label
            label.lineBreakMode = .byTruncatingTail
            card.addSubview(label)
            constraints += [
                label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: Self.captionGap),
                label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: ratio == nil ? Self.spacing : 0),
                label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: ratio == nil ? -Self.spacing : 0),
                label.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor),
            ]
        } else {
            constraints.append(imageView.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return card
    }

    private func makePagerButton(symbol: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = .white
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.4
        button.layer.shadowRadius = 3
        button.layer.shadowOffset = .zero
        button.addTarget(self, action: action, for: .touchUpInside)
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 36),
        ])
        return button
    }

    private func pin(_ subview: UIView, insets: UIEdgeInsets) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            subview.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            subview.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            subview.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
        ])
    }

    private func setSingleAspect(_ ratio: CGFloat) {
        let clamped = min(max(ratio, 0.3), 1.5)
        singleRatio = clamped
        if let current = singleAspect, let imageView = imageViews.first {
            current.isActive = false
            let aspect = imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: clamped)
            aspect.isActive = true
            singleAspect = aspect
        }
        updateLayout(width: availableWidth)
    }

    // MARK: - Images

    /// Card 0 comes from the Service Extension's attachment when present, so its view is not
    /// counted twice. Other cards are fetched when shown: through the tracker, that fetch IS
    /// the view. The fetch is a download to a file, capped at `RichPush.maxCardImageBytes`,
    /// and the image is decoded downsampled.
    private func loadImage(at index: Int) {
        guard let payload, imageViews.indices.contains(index), !loaded.contains(index), downloads[index] == nil
        else { return }
        if index == 0, let attachmentImage {
            loaded.insert(0)
            setImage(attachmentImage, at: 0)
            return
        }
        guard let url = payload.imageURL(at: index) else { return }
        let generation = self.generation
        let download = BearoundBoundedDownload(
            url: url, maxBytes: RichPush.maxCardImageBytes, timeout: Self.cardImageTimeout
        ) { [weak self] file, response in
            var image: UIImage?
            if let file {
                let ok = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? true
                if ok, let cgImage = RichPush.downsampledImage(at: file) { image = UIImage(cgImage: cgImage) }
                try? FileManager.default.removeItem(at: file)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.downloads[index] = nil
                // On failure the card stays out of `loaded`: showing it again retries.
                guard let image else { return }
                self.loaded.insert(index)
                self.setImage(image, at: index)
            }
        }
        downloads[index] = download
        download.start()
    }

    private func setImage(_ image: UIImage, at index: Int) {
        guard imageViews.indices.contains(index) else { return }
        imageViews[index].image = image
        if index == 0, singleAspect != nil, image.size.width > 0 {
            setSingleAspect(image.size.height / image.size.width)
        }
    }

    private static func attachmentImage(in content: UNNotificationContent) -> UIImage? {
        guard let attachment = content.attachments.first(where: { $0.identifier == RichPush.attachmentIdentifier })
        else { return nil }
        let url = attachment.url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return RichPush.downsampledImage(at: url).map { UIImage(cgImage: $0) }
    }

    // MARK: - Carousel paging

    @objc private func showPrevious() { scroll(to: currentPage - 1) }
    @objc private func showNext() { scroll(to: currentPage + 1) }

    private func scroll(to page: Int) {
        guard let scrollView, let payload, payload.cards.indices.contains(page) else { return }
        scrollView.setContentOffset(CGPoint(x: CGFloat(page) * scrollView.bounds.width, y: 0), animated: true)
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { pageDidChange() }
    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { pageDidChange() }

    private func pageDidChange() {
        guard let scrollView, scrollView.bounds.width > 0 else { return }
        currentPage = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
        loadImage(at: currentPage)
        updatePager()
    }

    private func updatePager() {
        let count = payload?.cards.count ?? 0
        prevButton?.isHidden = currentPage <= 0
        nextButton?.isHidden = currentPage >= count - 1
    }

    // MARK: - Taps

    @objc private func cardTapped(_ sender: UITapGestureRecognizer) {
        openCard(at: sender.view?.tag ?? 0)
    }

    /// A card with an allowed URL (http(s), or a scheme the host app declares) opens it and,
    /// once the system confirms it opened, reports the open, since the host app never sees
    /// this tap. Any other card opens the app like a regular notification tap, where the SDK
    /// reports the open.
    private func openCard(at index: Int) {
        guard let payload else { return }
        guard let url = payload.tapURL(at: index, hostSchemes: hostSchemes) else {
            extensionContext?.performNotificationDefaultAction()
            return
        }
        let openHit = payload.tracking.flatMap { RichPush.openURL($0) }
        // Strong `self`: the controller and its session must outlive the open to send the hit.
        extensionContext?.open(url) { success in
            guard success, let openHit else { return }
            DispatchQueue.main.async { self.sendOpenHit(openHit) }
        }
    }

    private func sendOpenHit(_ url: URL) {
        let task = session.dataTask(with: url) { _, _, _ in
            DispatchQueue.main.async { self.openHitTask = nil }
        }
        openHitTask = task
        task.resume()
    }
}
