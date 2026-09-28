//
//  BearoundNotificationViewController.swift
//  BearoundSDK/NotificationContent
//
//  Notification Content Extension for Bearound rich push. Draws the cards of a
//  `bearound_rich` payload programmatically (no storyboard): one image, two side-by-side
//  cards, a paged carousel, or a cover with a play glyph. Extension-safe: does not depend on
//  the core SDK.
//
//  Host usage (the whole NotificationViewController.swift of the host's content extension):
//
//      import BearoundSDK
//      class NotificationViewController: BearoundNotificationViewController {}
//
//  The extension's Info.plist declares `BearoundPushCategory.all` as
//  `UNNotificationExtensionCategory` and `UNNotificationExtensionUserInteractionEnabled = YES`
//  (without it card taps do nothing).
//

import UIKit
import UserNotifications
import UserNotificationsUI

open class BearoundNotificationViewController: UIViewController, UNNotificationContentExtension, UIScrollViewDelegate {
    private static let spacing: CGFloat = 8
    private static let captionHeight: CGFloat = 18
    /// Two-image cards are uploaded at up to 1080x608.
    private static let twoImagesRatio: CGFloat = 608.0 / 1080.0
    private static let carouselRatio: CGFloat = 0.75

    private let container = UIView()
    private var payload: RichPushPayload?
    private var attachmentImage: UIImage?
    private var imageViews: [UIImageView] = []
    private var requested = Set<Int>()
    private var singleAspect: NSLayoutConstraint?
    private var singleHasCaption = false
    private weak var scrollView: UIScrollView?
    private weak var prevButton: UIButton?
    private weak var nextButton: UIButton?
    private var currentPage = 0

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
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

    // MARK: - Layout

    private var availableWidth: CGFloat {
        view.bounds.width > 0 ? view.bounds.width : 320
    }

    private func render(_ content: UNNotificationContent) {
        container.subviews.forEach { $0.removeFromSuperview() }
        imageViews = []
        requested = []
        singleAspect = nil
        currentPage = 0

        payload = RichPushPayload.parse(content.userInfo)
        attachmentImage = Self.attachmentImage(in: content)
        guard let payload else {
            preferredContentSize = CGSize(width: availableWidth, height: 0)
            return
        }

        switch payload.format {
        case .image, .play: buildSingle(payload)
        case .twoImages: buildTwoImages(payload)
        case .carousel: buildCarousel(payload)
        }
    }

    private func buildSingle(_ payload: RichPushPayload) {
        let width = availableWidth
        let card = makeCard(index: 0, caption: payload.cards[0].caption, ratio: nil)
        if payload.format == .play, let imageView = imageViews.first {
            let glyph = UIImageView(image: UIImage(systemName: "play.circle.fill"))
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.tintColor = .white
            glyph.layer.shadowColor = UIColor.black.cgColor
            glyph.layer.shadowOpacity = 0.4
            glyph.layer.shadowRadius = 4
            glyph.layer.shadowOffset = .zero
            imageView.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
                glyph.widthAnchor.constraint(equalToConstant: 64),
                glyph.heightAnchor.constraint(equalToConstant: 64),
            ])
        }
        pin(card, insets: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
        singleHasCaption = payload.cards[0].caption != nil
        setSingleAspect(1, width: width)
        loadImage(at: 0)
    }

    private func buildTwoImages(_ payload: RichPushPayload) {
        let width = availableWidth
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

        let cardWidth = (width - 3 * Self.spacing) / 2
        let hasCaption = payload.cards.contains { $0.caption != nil }
        let height = 2 * Self.spacing + cardWidth * Self.twoImagesRatio + (hasCaption ? Self.captionHeight + 4 : 0)
        preferredContentSize = CGSize(width: width, height: ceil(height))
        payload.cards.indices.forEach { loadImage(at: $0) }
    }

    private func buildCarousel(_ payload: RichPushPayload) {
        let width = availableWidth
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
        let imageHeight = (width - 2 * Self.spacing) * Self.carouselRatio
        NSLayoutConstraint.activate([
            prev.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.spacing * 2),
            next.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.spacing * 2),
            prev.centerYAnchor.constraint(equalTo: container.topAnchor, constant: Self.spacing + imageHeight / 2),
            next.centerYAnchor.constraint(equalTo: prev.centerYAnchor),
        ])
        prevButton = prev
        nextButton = next

        let hasCaption = payload.cards.contains { $0.caption != nil }
        let height = 2 * Self.spacing + imageHeight + (hasCaption ? Self.captionHeight + 4 : 0)
        preferredContentSize = CGSize(width: width, height: ceil(height))
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
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.text = caption
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .label
            label.lineBreakMode = .byTruncatingTail
            card.addSubview(label)
            constraints += [
                label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
                label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: ratio == nil ? Self.spacing : 0),
                label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: ratio == nil ? -Self.spacing : 0),
                label.heightAnchor.constraint(equalToConstant: Self.captionHeight),
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

    private func setSingleAspect(_ ratio: CGFloat, width: CGFloat) {
        let clamped = min(max(ratio, 0.3), 1.5)
        if let current = singleAspect, let imageView = imageViews.first {
            current.isActive = false
            let aspect = imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: clamped)
            aspect.isActive = true
            singleAspect = aspect
        }
        let height = width * clamped + (singleHasCaption ? Self.captionHeight + 4 + Self.spacing : 0)
        preferredContentSize = CGSize(width: width, height: ceil(height))
    }

    // MARK: - Images

    /// Card 0 comes from the Service Extension's attachment when present, so its view is not
    /// counted twice. Other cards are fetched when shown: through the tracker, that fetch IS
    /// the view.
    private func loadImage(at index: Int) {
        guard let payload, imageViews.indices.contains(index), !requested.contains(index) else { return }
        requested.insert(index)
        if index == 0, let attachmentImage {
            setImage(attachmentImage, at: 0)
            return
        }
        guard let url = payload.imageURL(at: index) else { return }
        session.dataTask(with: url) { [weak self] data, response, _ in
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return }
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { self?.setImage(image, at: index) }
        }.resume()
    }

    private func setImage(_ image: UIImage, at index: Int) {
        guard imageViews.indices.contains(index) else { return }
        imageViews[index].image = image
        if index == 0, singleAspect != nil, image.size.width > 0 {
            setSingleAspect(image.size.height / image.size.width, width: availableWidth)
        }
    }

    private static func attachmentImage(in content: UNNotificationContent) -> UIImage? {
        guard let attachment = content.attachments.first(where: { $0.identifier == RichPush.attachmentIdentifier })
        else { return nil }
        let url = attachment.url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
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

    /// A card with a URL opens it (http(s) through the tracker click, a deep link directly)
    /// and reports the open, since the host app never sees this tap. A card without a URL
    /// opens the app like a regular notification tap, where the SDK reports the open.
    private func openCard(at index: Int) {
        guard let payload else { return }
        guard let url = payload.tapURL(at: index) else {
            extensionContext?.performNotificationDefaultAction()
            return
        }
        if let tracking = payload.tracking, let open = RichPush.openURL(tracking) {
            session.dataTask(with: open).resume()
        }
        extensionContext?.open(url, completionHandler: nil)
    }
}
