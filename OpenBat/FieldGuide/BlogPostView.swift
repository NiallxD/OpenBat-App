//
//  BlogPostView.swift
//  OpenBat
//
//  Reads one post. The body arrives as a rendered HTML fragment (see
//  `BlogFeedSpec.md`) and is shown in a web view wearing the app's own
//  stylesheet — app fonts, app colours, app dark mode — so it reads as a screen
//  in OpenBat rather than as a website in a box.
//
//  **Why a web view at all, in an app that had no WebKit in it until now.** The
//  posts use Obsidian callouts, a collapsible sources block, cross-links and
//  seven data figures, and the website's build has already turned every one of
//  those into HTML. Rendering the Markdown natively would mean reimplementing
//  all of it in Swift and then re-implementing whatever Niall writes next; the
//  first new callout type in a post would be an app bug. This way a post is
//  finished content and the app supplies only the typography.
//
//  Nothing remote is loaded except images. The fragment carries no script and no
//  stylesheet of its own — the spec forbids both — and the navigation delegate
//  below refuses to follow any link in place, so there is no way for this view
//  to become a browser.
//

import SwiftUI
import WebKit

struct BlogPostView: View {
    let post: BlogPost
    let store: BlogStore
    /// Pushing is the stack owner's job, not this view's.
    ///
    /// A nested `.navigationDestination(item:)` per pushed post was the obvious
    /// shape and the wrong one: this screen can push another copy of itself, so
    /// each copy would declare another destination for the same type. The guide's
    /// own enum carries a note about exactly that going wrong — a second
    /// destination for a type already routed by the stack desyncs it, and the
    /// pushed screen shows the previous one's content until you go back and
    /// forward again. One destination, declared once, at the stack.
    let onOpenPost: (BlogPost) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    /// A link that leaves the app, held for confirmation. Opening Safari from
    /// under someone's thumb without asking is the kind of thing that loses a
    /// reader their place.
    @State private var externalLink: URL?
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        // **The cover bleeds, the reading does not.** `.pageColumn()` was on the
        // stack INSIDE the scroll view, where it does nothing at all: it works by
        // `contentMargins(for: .scrollContent)`, which is a property of a scroll
        // view rather than of its contents, so the text ran to both screen edges
        // and nothing said so. The column is applied to the reading here, and the
        // cover image deliberately sits outside it, full width.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cover
                VStack(alignment: .leading, spacing: 0) {
                    titleBlock
                    BlogHTMLView(html: post.html,
                                 colorScheme: colorScheme,
                                 contentHeight: $contentHeight,
                                 onInternalLink: { id in
                                     if let next = store.post(id: id) { onOpenPost(next) }
                                 },
                                 onExternalLink: { externalLink = $0 })
                        .frame(height: contentHeight)
                    footer
                }
                .pageColumnFrame()
                .padding(.horizontal, Self.readingMargin)
            }
        }
        .navigationTitle(post.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: post.url) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .alert("Open in Safari?",
               isPresented: .init(get: { externalLink != nil },
                                  set: { if !$0 { externalLink = nil } })) {
            Button("Open") { if let externalLink { openURL(externalLink) } }
            Button("Cancel", role: .cancel) { externalLink = nil }
        } message: {
            Text(externalLink?.host.map { "This link goes to \($0)." } ?? "")
        }
    }

    /// Side margin for the reading column. `PageColumn` handles the iPad measure
    /// through `pageColumnFrame`; this is the phone's own gutter, which that
    /// modifier does not add.
    private static let readingMargin: CGFloat = 20

    /// Full width, cornerless, no inset — it is the top of the page rather than
    /// an illustration within it.
    @ViewBuilder private var cover: some View {
        if let coverImage = post.coverImage {
            AsyncImage(url: coverImage) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    // Not a spinner: a cover image is decoration, and a spinner
                    // above the title reads as the post failing to load when it
                    // is already fully readable below.
                    Color.primary.opacity(0.06)
                }
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .clipped()
            .padding(.bottom, 16)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(post.title)
                .font(.title2.bold())
            HStack(spacing: 6) {
                Text(post.displayDate)
                if let minutes = post.readingMinutes {
                    Text("·")
                    Text("\(minutes) min read")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private var footer: some View {
        if !post.tags.isEmpty {
            Divider().padding(.vertical, 12)
            Text(post.tags.map { "#\($0)" }.joined(separator: "  "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Button {
            externalLink = post.url
        } label: {
            Label("Read on openbat.app", systemImage: "safari")
                .font(.footnote)
        }
        .padding(.top, 16)
        .padding(.bottom, 24)
    }
}

extension BlogPostView {
    /// The rendered document, for tests. The stylesheet is behaviour — it is what
    /// decides that a chart shows its table rather than an empty canvas — so it
    /// needs to be assertable without standing up a web view.
    static func documentForTesting(fragment: String, dark: Bool) -> String {
        BlogHTMLView.document(fragment: fragment, dark: dark)
    }
}

// MARK: The web view

/// A `WKWebView` that renders one fragment and never navigates.
///
/// It reports its own content height back so the whole post scrolls as part of
/// the SwiftUI page — a web view left to scroll itself inside a `ScrollView`
/// gives you two scrollers fighting, and the header above it would be pinned
/// while the text moved underneath.
private struct BlogHTMLView: UIViewRepresentable {
    let html: String
    let colorScheme: ColorScheme
    @Binding var contentHeight: CGFloat
    let onInternalLink: (String) -> Void
    let onExternalLink: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInternalLink: onInternalLink,
                    onExternalLink: onExternalLink,
                    contentHeight: $contentHeight)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The fragment carries no script of its own, and this makes that a
        // property of the view rather than a promise about the content.
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        // The page does not scroll; its host does.
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        context.coordinator.observe(web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let document = Self.document(fragment: html, dark: colorScheme == .dark)
        guard context.coordinator.lastLoaded != document else { return }
        context.coordinator.lastLoaded = document
        // `baseURL` is the site, so a relative link the build let slip resolves
        // to the right page rather than to nothing. Images are absolute per the
        // spec; this is the safety net, not the mechanism.
        web.loadHTMLString(document, baseURL: URL(string: "https://openbat.app/"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onInternalLink: (String) -> Void
        let onExternalLink: (URL) -> Void
        @Binding var contentHeight: CGFloat
        var lastLoaded: String?
        private var observation: NSKeyValueObservation?

        init(onInternalLink: @escaping (String) -> Void,
             onExternalLink: @escaping (URL) -> Void,
             contentHeight: Binding<CGFloat>) {
            self.onInternalLink = onInternalLink
            self.onExternalLink = onExternalLink
            self._contentHeight = contentHeight
        }

        func webView(_ web: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The initial `loadHTMLString` is the only navigation ever allowed.
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            // `openbat://post/{id}` — a cross-reference to another post that is
            // also in the feed. The build emits these; see `BlogFeedSpec.md`.
            if url.scheme == "openbat", url.host == "post" {
                let id = url.lastPathComponent
                if !id.isEmpty { onInternalLink(id) }
            } else if url.scheme == "https" || url.scheme == "http" {
                onExternalLink(url)
            }
        }

        /// Watches the laid-out height instead of reading it once.
        ///
        /// **`didFinish` is the wrong moment and it fails silently.** It fires
        /// when the load completes, which is before WebKit has laid the content
        /// out, so `contentSize.height` reads 0 — the host frame stays at its
        /// initial 1 pt and the post renders as nothing at all. Nothing errors;
        /// the text is simply clipped to a hairline. Measuring once also misses
        /// every later reflow: an image arriving, or a Dynamic Type change.
        ///
        /// Scripting is off in this web view, so `document.scrollHeight` is not
        /// available to ask — which is just as well, since the scroll view's own
        /// content size is the number the SwiftUI frame actually needs.
        func observe(_ web: WKWebView) {
            observation = web.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, change in
                guard let self, let height = change.newValue?.height else { return }
                // The tolerance is a loop guard, not a nicety: setting the frame
                // resizes the web view, which lays out again and reports a new
                // size. Sub-point differences must not be allowed to feed back.
                guard height > 1, abs(height - self.contentHeight) > 1 else { return }
                self.contentHeight = height
            }
        }
    }

    /// Wraps the fragment in the app's typography. Colours are CSS variables set
    /// from the scheme rather than from `prefers-color-scheme`, because the app
    /// has its own appearance setting and the system's answer is not always the
    /// one the surrounding screen is using.
    static func document(fragment: String, dark: Bool) -> String {
        let text = dark ? "#f2f2f7" : "#1c1c1e"
        let dim = dark ? "#a1a1aa" : "#6c6c70"
        let rule = dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)"
        let panel = dark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.04)"
        let accent = "#ff8c2b"
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: \(dark ? "dark" : "light"); }
          html, body { margin: 0; padding: 0; background: transparent; }
          body {
            /* The shorthand, alone: it carries the user's Dynamic Type size as
               well as the face, and naming a font-family after it would keep the
               size while quietly dropping that link. */
            font: -apple-system-body;
            color: \(text);
            line-height: 1.55;
            -webkit-text-size-adjust: 100%;
          }
          h2 { font-size: 1.3em; margin: 1.6em 0 0.4em; }
          h3 { font-size: 1.1em; margin: 1.4em 0 0.3em; }
          p { margin: 0 0 1em; }
          a { color: \(accent); text-decoration: none; }
          img { max-width: 100%; height: auto; border-radius: 10px; }
          hr { border: 0; border-top: 1px solid \(rule); margin: 1.6em 0; }
          code { font-family: ui-monospace, monospace; font-size: 0.9em;
                 background: \(panel); padding: 0.1em 0.3em; border-radius: 4px; }
          pre { background: \(panel); padding: 12px; border-radius: 10px; overflow-x: auto; }
          pre code { background: none; padding: 0; }
          blockquote.callout {
            margin: 1.2em 0; padding: 12px 14px; border-radius: 10px;
            background: \(panel); border-left: 3px solid \(rule);
          }
          blockquote.callout > :last-child { margin-bottom: 0; }
          blockquote.callout-note    { border-left-color: #4a90d9; }
          blockquote.callout-tip     { border-left-color: #34c759; }
          blockquote.callout-warning { border-left-color: #ff9f0a; }
          details { margin: 1.4em 0; padding: 10px 14px; border-radius: 10px; background: \(panel); }
          summary { cursor: default; font-weight: 600; }
          table { width: 100%; border-collapse: collapse; margin: 1.2em 0; font-size: 0.92em; }
          th, td { text-align: left; padding: 7px 8px; border-bottom: 1px solid \(rule); }
          caption { caption-side: top; text-align: left; color: \(dim);
                    font-size: 0.9em; padding-bottom: 6px; }
          figure { margin: 1.4em 0; }
          figcaption { color: \(dim); font-size: 0.85em; margin-top: 6px; }
          /* Charts arrive as their table fallback — the app runs no JavaScript,
             so a canvas would be a blank box. The table is the same numbers. */
          figure.chart canvas { display: none; }
          figure.chart noscript { display: block; }
        </style></head><body>\(fragment)</body></html>
        """
    }
}
