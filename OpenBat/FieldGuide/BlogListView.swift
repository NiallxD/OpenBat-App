//
//  BlogListView.swift
//  OpenBat
//
//  The feed, reached from the Blog button beside the guide's search field.
//  Cards in the order the website chose — see `BlogFeed.orderedPosts`.
//

import SwiftUI

struct BlogListView: View {
    let store: BlogStore
    let onOpenPost: (BlogPost) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.posts) { post in
                    Button { onOpenPost(post) } label: {
                        BlogPostCard(post: post)
                    }
                    .buttonStyle(.plain)
                }
            }
            .pageColumn()
            .padding(.vertical, 12)
        }
        .overlay { if store.posts.isEmpty { emptyState } }
        .navigationTitle("Blog")
        .navigationBarTitleDisplayMode(.inline)
        // Pull-to-refresh forces the fetch, which is also the one path that is
        // allowed to spend data in Low Data Mode — the user asked for it.
        .refreshable { await store.refresh(force: true) }
        .task {
            await store.loadCached()
            await store.refresh()
        }
    }

    /// One state covers "not published yet", "first launch offline" and "the
    /// fetch failed", because from the reader's side they are the same thing:
    /// there is nothing to read and it is not their fault. The error text is
    /// shown only when there is one, and never over posts that did load.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No posts yet", systemImage: "text.book.closed")
        } description: {
            if store.isRefreshing {
                Text("Fetching…")
            } else if let error = store.lastRefreshError {
                Text(error)
            } else {
                Text("Writing from the project will appear here. Pull down to check again.")
            }
        }
    }
}

private struct BlogPostCard: View {
    let post: BlogPost

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cover = post.coverImage {
                AsyncImage(url: cover) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.primary.opacity(0.06)
                    }
                }
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .clipped()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(post.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                Text(post.excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text(post.displayDate)
                    if let minutes = post.readingMinutes {
                        Text("·")
                        Text("\(minutes) min")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .glassTile()
    }
}

/// A post as it appears in the guide's search results, alongside species rows.
///
/// Deliberately not a `BlogPostCard`: in the dropdown a post is one match among
/// species, and a card with a photograph in it would dominate a list it is only
/// a part of. The glyph is what says "this one is a post, not a bat".
struct BlogSearchRow: View {
    let post: BlogPost

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(post.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(post.excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
