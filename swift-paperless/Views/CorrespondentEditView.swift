//
//  CorrespondentEditView.swift
//  swift-paperless
//
//  Created by Paul Gessinger on 25.04.23.
//

import SwiftUI

struct CorrespondentEditView<Element>: View where Element: CorrespondentProtocol {
    @State private var element: Element
    var onSave: (Element) throws -> Void

    private var saveLabel: String

    init(element: Element, onSave: @escaping (Element) throws -> Void = { _ in }) {
        _element = State(initialValue: element)
        self.onSave = onSave
        saveLabel = "Save"
    }

    private func valid() -> Bool {
        return !element.name.isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $element.name)
                    .clearable($element.name)
            }

            MatchEditView(element: $element)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(saveLabel) {
                    do {
                        try onSave(element)
                    }
                    catch {
                        print("Save correspondent error: \(error)")
                    }
                }
                .disabled(!valid())
            }
        }
    }
}

extension CorrespondentEditView where Element == ProtoCorrespondent {
    init(onSave: @escaping (Element) throws -> Void = { _ in }) {
        self.init(element: ProtoCorrespondent(), onSave: onSave)
        saveLabel = "Add"
    }
}

struct CorrespondentEditView_Previews: PreviewProvider {
    struct Container: View {
        var body: some View {
            NavigationStack {
                CorrespondentEditView<ProtoCorrespondent>()
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationTitle("Create correspondent")
            }
        }
    }

    static var previews: some View {
        Container()
    }
}
