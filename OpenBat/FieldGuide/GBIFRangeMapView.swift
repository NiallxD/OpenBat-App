//
//  GBIFRangeMapView.swift
//  OpenBat
//
//  Interactive GBIF occurrence-density range map for the species detail
//  page. `MKTileOverlay` needs a raw MKMapView delegate to install the
//  tile renderer, so this wraps UIKit directly rather than using SwiftUI's
//  `Map` — same pattern as numbird's GBIFRangeMapView (Birding_Data).
//

import SwiftUI
import MapKit

/// UIViewRepresentable bridging a GBIF tile overlay onto a plain MKMapView.
struct GBIFRangeMapView: UIViewRepresentable {
    let taxonKey: Int
    /// Bounding region of the species' actual occurrence data, fetched
    /// alongside the taxon key — falls back to a whole-world view if the
    /// extent couldn't be determined (no data, or a network error).
    let initialRegion: MKCoordinateRegion?

    private static let worldFallback = MKCoordinateRegion(
        center: .init(latitude: 20, longitude: 0),
        span: .init(latitudeDelta: 170, longitudeDelta: 170))

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(initialRegion ?? Self.worldFallback, animated: false)
        map.addOverlay(GBIFService.rangeTileOverlay(taxonKey: taxonKey), level: .aboveLabels)
        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tileOverlay = overlay as? MKTileOverlay else { return MKOverlayRenderer(overlay: overlay) }
            return MKTileOverlayRenderer(tileOverlay: tileOverlay)
        }
    }
}

/// Card shown on the species detail page — resolves the taxon key, then
/// shows the map, a loading spinner, or an "unavailable" state.
struct GBIFDistributionCard: View {
    let species: GuideSpecies

    @State private var taxonKey: Int?
    @State private var region: MKCoordinateRegion?
    @State private var lookupFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let taxonKey {
                    GBIFRangeMapView(taxonKey: taxonKey, initialRegion: region)
                        .frame(height: 220)
                } else if lookupFailed {
                    ContentUnavailableView("Distribution unavailable",
                                           systemImage: "globe.desk",
                                           description: Text("Couldn't reach GBIF for this species."))
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView()
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                        .background(.quaternary)
                }
            }
            Text("Distribution data via GBIF.org")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .task(id: species.id) {
            taxonKey = nil
            region = nil
            lookupFailed = false
            guard let key = await GBIFService.fetchTaxonKey(for: species.scientificName) else {
                lookupFailed = true
                return
            }
            // Resolve the extent before setting `taxonKey` so GBIFRangeMapView
            // is only ever created once both are known — it's a raw
            // UIViewRepresentable that sets its region once in `makeUIView`
            // and never updates afterwards.
            region = await GBIFService.fetchOccurrenceExtent(taxonKey: key)
            taxonKey = key
        }
    }
}
