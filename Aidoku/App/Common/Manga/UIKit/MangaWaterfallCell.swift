//
//  MangaWaterfallCell.swift
//  Aidoku
//
//  A waterfall (masonry) cell in the nhentai style: the cover keeps its
//  original aspect ratio, and the title and tag chips sit below it in
//  the page's normal text colors. Item heights come from
//  WaterfallItemMetrics, shared with the SwiftUI waterfall surfaces.
//  An optional language badge sits on the cover's top-left corner.
//

import AidokuRunner
import Gifu
import Nuke
import UIKit

private final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }
}

private final class TagChipsView: UIView {
    private var chipLabels: [PaddedLabel] = []

    var tags: [String] = [] {
        didSet {
            for label in chipLabels {
                label.removeFromSuperview()
            }
            chipLabels = tags.map { tag in
                let label = PaddedLabel()
                label.text = tag
                label.font = WaterfallItemMetrics.tagFont
                label.textColor = .secondaryLabel
                label.backgroundColor = .tertiarySystemFill
                label.layer.cornerRadius = 6
                label.layer.masksToBounds = true
                label.lineBreakMode = .byTruncatingTail
                addSubview(label)
                return label
            }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rows = WaterfallItemMetrics.tagRows(tags: tags, width: bounds.width)
        var labelIndex = 0
        for (rowIndex, row) in rows.enumerated() {
            var x: CGFloat = 0
            let y = CGFloat(rowIndex) * (WaterfallItemMetrics.tagChipHeight + WaterfallItemMetrics.tagRowSpacing)
            for tag in row {
                guard labelIndex < chipLabels.count else { return }
                let label = chipLabels[labelIndex]
                labelIndex += 1
                let textWidth = ceil((tag as NSString).size(withAttributes: [.font: WaterfallItemMetrics.tagFont]).width)
                let width = min(
                    textWidth + WaterfallItemMetrics.tagChipHorizontalPadding,
                    bounds.width - x
                )
                label.frame = CGRect(x: x, y: y, width: width, height: WaterfallItemMetrics.tagChipHeight)
                x += width + WaterfallItemMetrics.tagChipSpacing
            }
        }
        // hide any chips that didn't fit into the capped rows
        for index in labelIndex..<chipLabels.count {
            chipLabels[index].frame = .zero
        }
    }
}

class MangaWaterfallCell: UICollectionViewCell {
    var identifier: MangaIdentifier?

    var showsBookmark: Bool {
        get { !bookmarkView.isHidden }
        set { bookmarkView.isHidden = !newValue }
    }

    var badgeNumber: Int {
        get { badgeView.badgeNumber }
        set {
            badgeView.badgeNumber = newValue
            setNeedsLayout()
        }
    }
    var badgeNumber2: Int {
        get { badgeView.badgeNumber2 }
        set {
            badgeView.badgeNumber2 = newValue
            setNeedsLayout()
        }
    }

    let imageView = GIFImageView()
    private let coverContainer = UIView()
    private let titleLabel = UILabel()
    private let chipsView = TagChipsView()
    private lazy var badgeView = DoubleBadgeView()
    private let bookmarkView = UIImageView()
    private let languageBadge = PaddedLabel()
    private let highlightView = UIView()

    private lazy var shadowOverlayView: UIView = {
        let shadowOverlayView = UIView()
        shadowOverlayView.alpha = 0
        shadowOverlayView.backgroundColor = UIColor(white: 0, alpha: 0.5)
        shadowOverlayView.layer.cornerRadius = 5
        shadowOverlayView.translatesAutoresizingMaskIntoConstraints = false
        return shadowOverlayView
    }()

    private lazy var selectionView = SelectionCheckView(style: .bordered)

    private var aspectRatio: CGFloat = 2.0 / 3.0
    private var title: String?
    private var tags: [String] = []

    private var url: String?
    private var imageTask: ImageTask?
    var isEditing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        coverContainer.clipsToBounds = true
        coverContainer.layer.cornerRadius = 5
        coverContainer.layer.borderWidth = 1
        coverContainer.layer.borderColor = UIColor.quaternarySystemFill.cgColor
        contentView.addSubview(coverContainer)

        imageView.image = UIImage(named: "MangaPlaceholder")
        imageView.contentMode = .scaleAspectFill
        coverContainer.addSubview(imageView)

        coverContainer.addSubview(badgeView)

        bookmarkView.isHidden = true
        bookmarkView.image = UIImage(named: "bookmark")
        bookmarkView.contentMode = .scaleAspectFit
        coverContainer.addSubview(bookmarkView)

        languageBadge.isHidden = true
        languageBadge.font = .systemFont(ofSize: 10, weight: .bold)
        languageBadge.textColor = .white
        languageBadge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        languageBadge.layer.cornerRadius = 4
        languageBadge.layer.masksToBounds = true
        languageBadge.insets = UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)
        coverContainer.addSubview(languageBadge)

        titleLabel.font = WaterfallItemMetrics.titleFont
        titleLabel.textColor = .label
        titleLabel.numberOfLines = WaterfallItemMetrics.titleMaxLines
        contentView.addSubview(titleLabel)

        contentView.addSubview(chipsView)

        highlightView.alpha = 0
        highlightView.backgroundColor = UIColor(white: 0, alpha: 0.5)
        highlightView.layer.cornerRadius = 5
        contentView.addSubview(highlightView)

        selectionView.isHidden = true
        contentView.addSubview(shadowOverlayView)
        contentView.addSubview(selectionView)
    }

    func setContent(
        title: String?,
        tags: [String],
        language: String?,
        aspectRatio: CGFloat,
        bookmarked: Bool
    ) {
        self.title = title
        self.tags = tags
        self.aspectRatio = aspectRatio
        titleLabel.text = title ?? NSLocalizedString("UNTITLED")
        chipsView.tags = tags
        chipsView.isHidden = tags.isEmpty
        if let language, !language.isEmpty {
            languageBadge.text = language.uppercased()
            languageBadge.isHidden = false
        } else {
            languageBadge.isHidden = true
        }
        showsBookmark = bookmarked
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        let coverHeight = width / min(max(aspectRatio, 0.2), 5)
        coverContainer.frame = CGRect(x: 0, y: 0, width: width, height: coverHeight)
        imageView.frame = coverContainer.bounds
        let badgeSize = badgeView.intrinsicContentSize
        badgeView.frame = CGRect(x: 5, y: 5, width: badgeSize.width, height: 20)
        bookmarkView.frame = CGRect(x: width - 8 - 17, y: 0, width: 17, height: 27)
        languageBadge.sizeToFit()
        languageBadge.frame = CGRect(
            x: 5,
            y: 5,
            width: languageBadge.bounds.width,
            height: WaterfallItemMetrics.tagChipHeight - 2
        )

        var y = coverHeight
        if let title, !title.isEmpty {
            y += WaterfallItemMetrics.textTopSpacing
            let lines = WaterfallItemMetrics.titleLineCount(title: title, width: width)
            titleLabel.frame = CGRect(
                x: 0,
                y: y,
                width: width,
                height: CGFloat(lines) * WaterfallItemMetrics.titleLineHeight
            )
            y += CGFloat(lines) * WaterfallItemMetrics.titleLineHeight
        } else {
            titleLabel.frame = .zero
        }
        if !tags.isEmpty {
            y += WaterfallItemMetrics.tagsTopSpacing
            let rows = WaterfallItemMetrics.tagRows(tags: tags, width: width).count
            chipsView.frame = CGRect(
                x: 0,
                y: y,
                width: width,
                height: CGFloat(rows) * WaterfallItemMetrics.tagChipHeight
                    + CGFloat(max(0, rows - 1)) * WaterfallItemMetrics.tagRowSpacing
            )
        } else {
            chipsView.frame = .zero
        }

        highlightView.frame = contentView.bounds
        shadowOverlayView.frame = contentView.bounds
        selectionView.frame = CGRect(
            x: contentView.bounds.width - 10 - 24,
            y: contentView.bounds.height - 10 - 24,
            width: 24,
            height: 24
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = UIImage(named: "MangaPlaceholder")
        imageTask?.cancel()
        imageTask = nil
        highlightView.alpha = 0
        titleLabel.text = nil
        chipsView.tags = []
        languageBadge.isHidden = true
        badgeView.badgeNumber = 0
        badgeView.badgeNumber2 = 0
    }
}

extension MangaWaterfallCell {
    func highlight() {
        highlightView.alpha = 1
    }

    func unhighlight(animated: Bool = true) {
        UIView.animate(withDuration: animated ? 0.3 : 0) {
            self.highlightView.alpha = 0
        }
    }

    func setEditing(_ editing: Bool, animated: Bool = true) {
        guard isEditing != editing else { return }
        isEditing = editing
        if editing {
            selectionView.setSelected(false, animated: false)
        }
        if animated {
            if editing {
                self.selectionView.isHidden = false
            }
            UIView.animate(withDuration: CATransaction.animationDuration()) {
                self.shadowOverlayView.alpha = editing ? 1 : 0
            } completion: { _ in
                if !editing {
                    self.selectionView.isHidden = true
                }
            }
        } else {
            self.shadowOverlayView.alpha = editing ? 1 : 0
            self.selectionView.isHidden = !editing
        }
    }

    func setSelected(_ selected: Bool, animated: Bool = true) {
        guard isEditing else { return }
        selectionView.setSelected(selected, animated: animated)
        if animated {
            UIView.animate(withDuration: CATransaction.animationDuration()) {
                self.shadowOverlayView.alpha = selected ? 0 : 1
            }
        } else {
            self.shadowOverlayView.alpha = selected ? 0 : 1
        }
    }
}

extension MangaWaterfallCell {
    func loadImage(url: URL?) async {
        guard let url else { return }
        let coverUrlString = url.absoluteString

        if let imageTask, imageTask.state == .running {
            return
        }

        self.imageView.stopAnimatingGIF()

        let source: AidokuRunner.Source? = if let sourceKey = identifier?.sourceKey {
            await SourceManager.shared.source(for: sourceKey)
        } else {
            nil
        }

        var urlRequest = URLRequest(url: url)
        var cached = ImagePipeline.shared.cache.containsCachedImage(for: .init(urlRequest: urlRequest))

        if !cached {
            if let fileUrl = url.toAidokuFileUrl() {
                urlRequest = URLRequest(url: fileUrl)
            } else if let source {
                urlRequest = await source.getModifiedImageRequest(url: url, context: nil)
            }
        }

        self.url = (urlRequest.url ?? url).absoluteString

        var processors: [ImageProcessing] = [DownsampleProcessor(width: bounds.width)]
        if let source, source.features.processesCovers {
            processors.append(CoverInterceptorProcessor(source: source))
        }

        let request = ImageRequest(
            urlRequest: urlRequest,
            processors: processors,
            userInfo: [.processesKey: source?.features.processesCovers ?? false]
        )

        cached = cached || ImagePipeline.shared.cache.containsCachedImage(for: request)

        imageTask = ImagePipeline.shared.loadImage(with: request) { [weak self] result in
            guard let self else { return }
            switch result {
                case .success(let response):
                    if response.request.imageID != self.url {
                        return
                    }
                    CoverAspectCache.shared.record(url: coverUrlString, size: response.image.size)
                    Task { @MainActor in
                        if cached {
                            self.imageView.image = response.image
                        } else {
                            UIView.transition(with: self.imageView, duration: 0.3, options: .transitionCrossDissolve) {
                                self.imageView.image = response.image
                            }
                        }
                        if response.container.type == .gif, let data = response.container.data {
                            self.imageView.animate(withGIFData: data)
                        }
                    }
                case .failure(let error):
                    imageTask = nil
                    guard let identifier else { return }
                    Task { @MainActor [weak self] in
                        guard
                            let newUrl = await CoverRecovery.recover(from: error, identifier: identifier),
                            self?.identifier == identifier
                        else { return }
                        await self?.loadImage(url: newUrl)
                    }
            }
        }
    }
}
