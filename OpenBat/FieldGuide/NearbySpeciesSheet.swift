//
//  NearbySpeciesSheet.swift
//  OpenBat
//
//  A quick "what's plausible around here" grid, reachable from the Detector's
//  nav bar without switching to the field guide tab. Reuses the same
//  presence join `SpeciesExplorerView.nearbySpecies` does — see that file for
//  the fuller, family-grouped version of this same list.
//
//  Photo-forward cards rather than the field guide's text rows — this is
//  meant to be skimmed at a glance ("what am I likely hearing tonight"), and
//  a face is faster to recognise than a species name.
//

import SwiftUI
import MapKit

struct NearbySpeciesSheet: View {
    let guide: SpeciesGuideStore
    let presenceStore: SpeciesPresenceStore
    let coordinate: CLLocationCoordinate2D?

    @Environment(\.dismiss) private var dismiss

    private var nearbySpecies: [GuideSpecies] {
        guard let coordinate else { return [] }
        return guide.guide.species.filter { species in
            guard let code = species.presenceCode else { return false }
            if case .present = presenceStore.presence(forCode: code, at: coordinate) { return true }
            return false
        }
    }

    private static let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if coordinate == nil {
                    ContentUnavailableView("No Location Yet",
                                            systemImage: "location.slash",
                                            description: Text("Bats near you will show up here once your location is available."))
                } else if nearbySpecies.isEmpty {
                    ContentUnavailableView("No Species Data",
                                            systemImage: "questionmark.circle",
                                            description: Text("Nothing in the field guide is known to be present at your location."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: Self.columns, spacing: 14) {
                            ForEach(nearbySpecies) { species in
                                NavigationLink {
                                    SpeciesDetailView(species: species, store: guide, presenceStore: presenceStore)
                                } label: {
                                    NearbySpeciesCard(species: species)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .navigationTitle("Bats Near You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// One grid tile — the species' photo fills the whole glass card, with the
/// common and scientific name legible over a bottom scrim. Same
/// contributor-URL-then-Wikipedia resolution `GuideSpeciesThumbnail`
/// (SpeciesExplorerView.swift) uses for the field guide's row thumbnails,
/// just sized to fill a card instead of a small row icon.
private struct NearbySpeciesCard: View {
    let species: GuideSpecies

    @State private var imageURL: URL?

    private var tint: Color {
        // Deterministic (not random) so the same family always gets the same
        // color across launches and across cards — matches
        // `GuideSpeciesThumbnail`'s placeholder.
        let hash = abs((species.family ?? species.order ?? "Chiroptera").hashValue)
        let palette: [Color] = [.orange, .teal, .indigo, .pink, .brown, .mint]
        return palette[hash % palette.count]
    }

    var body: some View {
        // `Color.clear` sizes the card from the grid column via the aspect
        // ratio; the photo and nameplate are hung off it as overlays rather
        // than sized by the image itself. Same reasoning as
        // `SpeciesDetailView.cardHeroPhoto`: an image-driven size blows the
        // layout out on a wide photo, and overlays can't expand their parent.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let imageURL {
                    AsyncImage(url: imageURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipped()
            .overlay(alignment: .bottom) { nameplate }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .task(id: species.scientificName) {
                // Contributor-set URL first — see `GuideSpecies.imageURL`'s
                // doc comment for why that's preferred over the live
                // Wikipedia lookup, which stays only as a fallback.
                if let urlString = species.imageURL, let url = URL(string: urlString) {
                    imageURL = url
                } else {
                    imageURL = await WikipediaSpeciesImageService.fetchImageURL(for: species.scientificName)
                }
            }
    }

    private var nameplate: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(species.commonName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(species.scientificName)
                .font(.caption2.italic())
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)],
                            startPoint: .top, endPoint: .bottom)
        )
    }

    private var placeholder: some View {
        Image("batIcon")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tint.gradient)
    }
}
