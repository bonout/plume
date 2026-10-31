import AppKit
import CoreText
import Foundation

struct Doc {
    let path: String
    let title: String
    let subtitle: String
    let body: [String]
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: demo-files.swift <output folder> en|fr\n".utf8))
    exit(1)
}
let output = URL(filePath: arguments[1], directoryHint: .isDirectory)
let french = arguments[2] == "fr"

let accent = NSColor(red: 0.184, green: 0.478, blue: 0.910, alpha: 1)

func lorem(_ seed: Int) -> String {
    let en = [
        "The goal is to keep the scope small and the result easy to maintain.",
        "Every decision is written down with its reason, so it can be revisited later.",
        "Costs are estimated with a margin of ten percent for unexpected work.",
        "The schedule leaves a week between each step for review and feedback.",
        "Questions and changes go through the shared notes before each meeting.",
        "Deliverables are stored in the project folder and named by date.",
    ]
    let fr = [
        "L'objectif est de garder un périmètre réduit et un résultat simple à maintenir.",
        "Chaque décision est notée avec sa raison, pour pouvoir y revenir plus tard.",
        "Les coûts sont estimés avec une marge de dix pour cent pour les imprévus.",
        "Le planning laisse une semaine entre chaque étape pour relire et commenter.",
        "Les questions et changements passent par les notes partagées avant chaque réunion.",
        "Les livrables sont rangés dans le dossier du projet et nommés par date.",
    ]
    let lines = french ? fr : en
    return (0..<3).map { lines[($0 + seed) % lines.count] }.joined(separator: " ")
}

func pdf(_ doc: Doc) throws {
    let url = output.appending(path: doc.path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
    context.beginPDFPage(nil)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    accent.setFill()
    CGRect(x: 0, y: 782, width: 595, height: 60).fill()
    func draw(_ text: String, _ font: NSFont, _ color: NSColor, _ rect: CGRect) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            .draw(with: rect, options: [.usesLineFragmentOrigin])
    }
    draw(doc.title, .systemFont(ofSize: 26, weight: .bold), .black, CGRect(x: 56, y: 700, width: 483, height: 60))
    draw(doc.subtitle, .systemFont(ofSize: 13), .darkGray, CGRect(x: 56, y: 670, width: 483, height: 24))
    var y: CGFloat = 630
    for (index, paragraph) in doc.body.enumerated() {
        let isHeading = paragraph.hasPrefix("#")
        let text = isHeading ? String(paragraph.dropFirst(2)) : paragraph
        let font: NSFont = isHeading ? .systemFont(ofSize: 15, weight: .semibold) : .systemFont(ofSize: 11.5)
        let height: CGFloat = isHeading ? 24 : 70
        draw(text, font, isHeading ? accent : .black, CGRect(x: 56, y: y - height + 18, width: 483, height: height))
        y -= height + (isHeading ? 0 : 6)
        if y < 80 || index > 12 { break }
    }
    context.endPDFPage()
    context.closePDF()
}

func text(_ path: String, _ content: String) throws {
    let url = output.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
}

func section(_ heading: String, _ seed: Int) -> [String] { ["# " + heading, lorem(seed)] }

let docs: [Doc]
let notes: [(String, String)]
if french {
    docs = [
        Doc(path: "Documents/CV 2026.pdf", title: "Camille Laurent", subtitle: "Cheffe de projet numérique · Lyon",
            body: section("Expérience", 0) + section("Formation", 1) + section("Compétences", 2)),
        Doc(path: "Documents/Lettre de motivation.pdf", title: "Lettre de motivation", subtitle: "Candidature, mars 2026",
            body: [lorem(3), lorem(4), lorem(5)]),
        Doc(path: "Documents/Bail de location.pdf", title: "Bail de location", subtitle: "Appartement, 3 pièces",
            body: section("Durée", 1) + section("Loyer et charges", 2) + section("Dépôt de garantie", 3)),
        Doc(path: "Projets/Refonte du site/Brief.pdf", title: "Refonte du site", subtitle: "Brief, version 2",
            body: section("Objectifs", 0) + section("Public", 3) + section("Calendrier", 4)),
        Doc(path: "Projets/Rénovation cuisine/Devis.pdf", title: "Devis n° 2026-118", subtitle: "Rénovation de cuisine",
            body: section("Travaux", 2) + section("Montant", 5)),
        Doc(path: "Projets/Rénovation cuisine/Plan.pdf", title: "Plan de la cuisine", subtitle: "Échelle 1:50",
            body: section("Implantation", 1) + section("Électricité", 4)),
        Doc(path: "Impôts/Déclaration 2025.pdf", title: "Déclaration de revenus 2025", subtitle: "Récapitulatif",
            body: section("Revenus", 0) + section("Déductions", 5)),
        Doc(path: "Impôts/Factures/Facture d'électricité.pdf", title: "Facture d'électricité", subtitle: "Janvier 2026",
            body: section("Consommation", 1) + section("Montant", 2)),
        Doc(path: "Impôts/Factures/Facture internet.pdf", title: "Facture internet", subtitle: "Février 2026",
            body: section("Abonnement", 3)),
        Doc(path: "Voyages/Islande 2026/Itinéraire.pdf", title: "Islande, juin 2026", subtitle: "Itinéraire sur dix jours",
            body: section("Reykjavik", 0) + section("Côte sud", 1) + section("Fjords de l'Est", 2)),
        Doc(path: "Voyages/Islande 2026/Confirmation de réservation.pdf", title: "Confirmation de réservation",
            subtitle: "Référence K7Q2LM", body: section("Séjour", 4)),
    ]
    notes = [
        ("Documents/Compte rendu de réunion.md", "# Compte rendu\n\n- Valider le planning\n- Envoyer le devis\n- Prochaine réunion jeudi\n"),
        ("Documents/Liste de lecture.md", "# À lire\n\n- L'Écume des jours\n- Le Petit Prince\n- Vingt mille lieues sous les mers\n"),
        ("Projets/Refonte du site/Planning.md", "# Planning\n\n1. Maquettes\n2. Développement\n3. Mise en ligne\n"),
        ("Projets/Rénovation cuisine/Checklist.md", "# Checklist\n\n- [x] Devis signé\n- [ ] Commande des meubles\n- [ ] Plombier\n"),
        ("Voyages/Islande 2026/Liste de bagages.md", "# Bagages\n\n- Veste imperméable\n- Chaussures de marche\n- Adaptateur\n"),
    ]
} else {
    docs = [
        Doc(path: "Documents/Résumé 2026.pdf", title: "Alex Martin", subtitle: "Product designer · Lisbon",
            body: section("Experience", 0) + section("Education", 1) + section("Skills", 2)),
        Doc(path: "Documents/Cover letter.pdf", title: "Cover letter", subtitle: "Application, March 2026",
            body: [lorem(3), lorem(4), lorem(5)]),
        Doc(path: "Documents/Lease agreement.pdf", title: "Lease agreement", subtitle: "Two-bedroom apartment",
            body: section("Term", 1) + section("Rent", 2) + section("Deposit", 3)),
        Doc(path: "Projects/Website redesign/Brief.pdf", title: "Website redesign", subtitle: "Brief, version 2",
            body: section("Goals", 0) + section("Audience", 3) + section("Schedule", 4)),
        Doc(path: "Projects/Kitchen renovation/Quote.pdf", title: "Quote #2026-118", subtitle: "Kitchen renovation",
            body: section("Work", 2) + section("Total", 5)),
        Doc(path: "Projects/Kitchen renovation/Floor plan.pdf", title: "Kitchen floor plan", subtitle: "Scale 1:50",
            body: section("Layout", 1) + section("Electrical", 4)),
        Doc(path: "Taxes/Tax return 2025.pdf", title: "Tax return 2025", subtitle: "Summary",
            body: section("Income", 0) + section("Deductions", 5)),
        Doc(path: "Taxes/Receipts/Electricity bill.pdf", title: "Electricity bill", subtitle: "January 2026",
            body: section("Usage", 1) + section("Amount", 2)),
        Doc(path: "Taxes/Receipts/Internet bill.pdf", title: "Internet bill", subtitle: "February 2026",
            body: section("Plan", 3)),
        Doc(path: "Travel/Iceland 2026/Itinerary.pdf", title: "Iceland, June 2026", subtitle: "Ten-day itinerary",
            body: section("Reykjavik", 0) + section("South coast", 1) + section("East fjords", 2)),
        Doc(path: "Travel/Iceland 2026/Booking confirmation.pdf", title: "Booking confirmation",
            subtitle: "Reference K7Q2LM", body: section("Stay", 4)),
    ]
    notes = [
        ("Documents/Meeting notes.md", "# Meeting notes\n\n- Approve the schedule\n- Send the quote\n- Next meeting Thursday\n"),
        ("Documents/Reading list.md", "# To read\n\n- The Left Hand of Darkness\n- A Wizard of Earthsea\n- Middlemarch\n"),
        ("Projects/Website redesign/Timeline.md", "# Timeline\n\n1. Wireframes\n2. Build\n3. Launch\n"),
        ("Projects/Kitchen renovation/Checklist.md", "# Checklist\n\n- [x] Quote signed\n- [ ] Order cabinets\n- [ ] Plumber\n"),
        ("Travel/Iceland 2026/Packing list.md", "# Packing\n\n- Rain jacket\n- Hiking boots\n- Adapter\n"),
    ]
}

for doc in docs { try pdf(doc) }
for (path, content) in notes { try text(path, content) }
print("\(docs.count) PDFs and \(notes.count) notes in \(output.path(percentEncoded: false))")
