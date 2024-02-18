//
//  Api.swift
//  swift-paperless
//
//  Created by Paul Gessinger on 18.02.23.
//

import Foundation
import os
import Semaphore
import SwiftUI
import UIKit

enum CrudOperation: String {
    case create
    case read
    case update
    case delete
}

struct CrudApiError<Element>: Error, LocalizedError {
    var operation: CrudOperation
    var type: Element.Type
    var status: Int?
    var body: String? = nil

    init(operation: CrudOperation, type: Element.Type, status: Int? = nil, body: String? = nil) {
        self.operation = operation
        self.type = type
        self.status = status
        self.body = body
    }

    init(operation: CrudOperation, type: Element.Type, status: Int? = nil, data: Data) {
        self.operation = operation
        self.type = type
        self.status = status
        body = String(decoding: data, as: UTF8.self)
    }

    var errorDescription: String? {
        "Failed to \(operation.rawValue) \(type)"
    }

    var failureReason: String? {
        "Backend replied with unexpected status: \(String(describing: status))" + (body != nil ? " \(body!)" : "")
    }
}

class ApiSequence<Element>: AsyncSequence, AsyncIteratorProtocol where Element: Decodable {
    private var nextPage: URL?
    private let repository: ApiRepository

    private var buffer: [Element]?
    private var bufferIndex = 0

    private(set) var hasMore = true

    private let semaphore = AsyncSemaphore(value: 1)

    init(repository: ApiRepository, url: URL) {
        self.repository = repository
        nextPage = url
    }

    func xprint(_ s: String) {
        if Element.self == Document.self {
            print(s)
        }
    }

    func next() async -> Element? {
        await semaphore.wait()
        defer { semaphore.signal() }

        guard !Task.isCancelled else {
            Logger.api.notice("API sequence next task was cancelled.")
            return nil
        }

        // if we have a current page loaded, return next element from that
        if let buffer, bufferIndex < buffer.count {
            defer { bufferIndex += 1 }
            return buffer[bufferIndex]
        }

        guard let url = nextPage else {
            Logger.api.notice("API sequence has reached end (nextPage is nil)")
            hasMore = false
            return nil
        }

        do {
            let request = repository.request(url: url)
            let (data, _) = try await URLSession.shared.data(for: request)

            let decoded = try decoder.decode(ListResponse<Element>.self, from: data)

            guard !decoded.results.isEmpty else {
                Logger.api.notice("API sequence fetch was empty")
                hasMore = false
                return nil
            }

            nextPage = decoded.next
            buffer = decoded.results
            bufferIndex = 1 // set to one because we return the first element immediately
            return decoded.results[0]

        } catch {
            Logger.api.error("Error in API sequence: \(error)")
            return nil
        }
    }

    func makeAsyncIterator() -> ApiSequence {
        self
    }
}

class ApiDocumentSource: DocumentSource {
    typealias DocumentSequence = ApiSequence<Document>

    var sequence: DocumentSequence

    init(sequence: DocumentSequence) {
        self.sequence = sequence
    }

    func fetch(limit: UInt) async -> [Document] {
        guard sequence.hasMore else {
            return []
        }
        return await Array(sequence.prefix(Int(limit)))
    }

    func hasMore() async -> Bool { sequence.hasMore }
}

class ApiRepository {
    let connection: Connection

    private var apiVersion: UInt?
    private var backendVersion: (UInt, UInt, UInt)?

    init(connection: Connection) {
        self.connection = connection
        Logger.api.notice("Initializing ApiRespository with connection \(connection.url, privacy: .private) \(connection.token, privacy: .private)")

        Task {
            await ensureBackendVersions()

            if let apiVersion, let backendVersion {
                Logger.api.notice("Backend version info: API version: \(apiVersion), backend version: \(backendVersion.0).\(backendVersion.1).\(backendVersion.2)")
            } else {
                Logger.api.warning("Did not get backend version info")
            }
        }
    }

    private var apiToken: String {
        connection.token
    }

    func url(_ endpoint: Endpoint) -> URL {
        let connection = connection
        Logger.api.trace("Making API endpoint URL with \(connection.url) for \(endpoint.path)")
        return endpoint.url(url: connection.url)!
    }

    let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    fileprivate func request(url: URL) -> URLRequest {
        Logger.api.trace("Creating API request for URL \(url)")
        var request = URLRequest(url: url)
        request.setValue("Token \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; version=3", forHTTPHeaderField: "Accept")
        connection.extraHeaders.apply(toRequest: &request)
        return request
    }

    fileprivate func request(_ endpoint: Endpoint) -> URLRequest {
        request(url: url(endpoint))
    }

    private func get<T: Decodable & Model>(_ type: T.Type, id: UInt) async -> T? {
        let request = request(.single(T.self, id: id))

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if (response as? HTTPURLResponse)?.statusCode != 200 {
                Logger.shared.error("Getting \(type) with id \(id): Status was not 200")
                return nil
            }

            let correspondent = try decoder.decode(type, from: data)
            return correspondent
        } catch {
            Logger.api.error("Error getting \(type) with id \(id): \(error)")
            return nil
        }
    }

    private func all<T: Decodable & Model>(_: T.Type) async -> [T] {
        let sequence = ApiSequence<T>(repository: self,
                                      url: url(.listAll(T.self)))
        return await Array(sequence)
    }

    private func create<Element>(element: some Encodable, endpoint: Endpoint, returns: Element.Type) async throws -> Element where Element: Decodable {
        var request = request(endpoint)

        let body = try JSONEncoder().encode(element)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let hres = response as? HTTPURLResponse, hres.statusCode != 201 {
                let body = String(data: data, encoding: .utf8) ?? "No body"

                throw CrudApiError(operation: .create,
                                   type: returns,
                                   status: hres.statusCode,
                                   body: body)
            }

            let created = try decoder.decode(returns, from: data)
            return created
        } catch {
            Logger.api.error("Api create \(returns) failed: \(error)")
            throw error
        }
    }

    private func update<Element>(element: Element, endpoint: Endpoint) async throws -> Element where Element: Codable {
        var request = request(endpoint)

        let body = try encoder.encode(element)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let hres = response as? HTTPURLResponse, hres.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? "No body"

                throw CrudApiError(operation: .update,
                                   type: Element.self,
                                   status: hres.statusCode,
                                   body: body)
            }

            return try decoder.decode(Element.self, from: data)

        } catch {
            Logger.api.error("Api update \(Element.self) failed: \(error)")
            throw error
        }
    }

    private func delete<Element>(element _: Element, endpoint: Endpoint) async throws {
        var request = request(endpoint)
        request.httpMethod = "DELETE"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let hres = response as? HTTPURLResponse, hres.statusCode != 204 {
                let body = String(data: data, encoding: .utf8) ?? "No body"

                throw CrudApiError(operation: .delete,
                                   type: Element.self,
                                   status: hres.statusCode,
                                   body: body)
            }

        } catch {
            Logger.api.error("Api delete \(Element.self) failed: \(error)")
            throw error
        }
    }
}

extension ApiRepository: Repository {
    func update(document: Document) async throws -> Document {
        try await update(element: document, endpoint: .document(id: document.id))
    }

    func create(document: ProtoDocument, file: URL) async throws {
        Logger.api.notice("Creating document")
        var request = request(.createDocument())

        let mp = MultiPartFormDataRequest()
        mp.add(name: "title", string: document.title)

        if let corr = document.correspondent {
            mp.add(name: "correspondent", string: String(corr))
        }

        if let dt = document.documentType {
            mp.add(name: "document_type", string: String(dt))
        }

        for tag in document.tags {
            mp.add(name: "tags", string: String(tag))
        }

        try mp.add(name: "document", url: file)
        mp.addTo(request: &request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let hres = response as? HTTPURLResponse, hres.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? "No body"
                Logger.shared.error("Create response return code \(hres.statusCode) and body \(body)")
                throw CrudApiError(operation: .create, type: Document.self, status: hres.statusCode, body: body)
            }
        } catch {
            Logger.api.error("Error uploading document: \(error)")
            throw error
        }
    }

    func delete(document: Document) async throws {
        Logger.api.notice("Deleting document")
        try await delete(element: document, endpoint: .document(id: document.id))
    }

    func documents(filter: FilterState) -> any DocumentSource {
        Logger.api.notice("Getting document sequence for filter")
        return ApiDocumentSource(
            sequence: ApiSequence<Document>(repository: self,
                                            url: url(.documents(page: 1, filter: filter))))
    }

    func download(documentID: UInt) async -> URL? {
        Logger.api.notice("Downloading document")
        let request = request(.download(documentId: documentID))

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if (response as? HTTPURLResponse)?.statusCode != 200 {
                Logger.shared.error("Downloading document: Status was not 200: \(String(decoding: data, as: UTF8.self))")
                return nil
            }

            guard let response = response as? HTTPURLResponse else {
                Logger.shared.error("Cannot get http response")
                return nil
            }

            guard let suggestedFilename = response.suggestedFilename else {
                Logger.api.error("Cannot get suggested filename from response")
                return nil
            }

            let temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let temporaryFileURL = temporaryDirectoryURL.appendingPathComponent(suggestedFilename)

            try data.write(to: temporaryFileURL, options: .atomic)
            try await Task.sleep(for: .seconds(0.2)) // wait a little bit for the data to be flushed
            return temporaryFileURL

        } catch {
            Logger.api.error("Error downloading document: \(error)")
            return nil
        }
    }

    func tag(id: UInt) async -> Tag? { await get(Tag.self, id: id) }

    func create(tag: ProtoTag) async throws -> Tag {
        try await create(element: tag, endpoint: .createTag(), returns: Tag.self)
    }

    func update(tag: Tag) async throws -> Tag {
        try await update(element: tag, endpoint: .tag(id: tag.id))
    }

    func delete(tag: Tag) async throws {
        try await delete(element: tag, endpoint: .tag(id: tag.id))
    }

    func tags() async -> [Tag] { await all(Tag.self) }

    func correspondent(id: UInt) async -> Correspondent? { await get(Correspondent.self, id: id) }

    func create(correspondent: ProtoCorrespondent) async throws -> Correspondent {
        try await create(element: correspondent,
                         endpoint: .createCorrespondent(),
                         returns: Correspondent.self)
    }

    func update(correspondent: Correspondent) async throws -> Correspondent {
        try await update(element: correspondent,
                         endpoint: .correspondent(id: correspondent.id))
    }

    func delete(correspondent: Correspondent) async throws {
        try await delete(element: correspondent,
                         endpoint: .correspondent(id: correspondent.id))
    }

    func correspondents() async -> [Correspondent] { await all(Correspondent.self) }

    func documentType(id: UInt) async -> DocumentType? { await get(DocumentType.self, id: id) }

    func create(documentType: ProtoDocumentType) async throws -> DocumentType {
        try await create(element: documentType,
                         endpoint: .createDocumentType(),
                         returns: DocumentType.self)
    }

    func update(documentType: DocumentType) async throws -> DocumentType {
        try await update(element: documentType,
                         endpoint: .documentType(id: documentType.id))
    }

    func delete(documentType: DocumentType) async throws {
        try await delete(element: documentType,
                         endpoint: .documentType(id: documentType.id))
    }

    func documentTypes() async -> [DocumentType] { await all(DocumentType.self) }

    func document(id: UInt) async -> Document? { await get(Document.self, id: id) }

    func document(asn: UInt) async -> Document? {
        Logger.api.notice("Getting document by ASN")
        let endpoint = Endpoint.documents(page: 1, rules: [FilterRule(ruleType: .asn, value: .number(value: Int(asn)))])

        let request = request(endpoint)

        do {
            let (data, res) = try await URLSession.shared.data(for: request)

            guard (res as? HTTPURLResponse)?.statusCode == 200 else {
                Logger.shared.error("Error fetching document by ASN \(asn): status code != 200. \(String(decoding: data, as: UTF8.self))")
                return nil
            }

            let decoded = try decoder.decode(ListResponse<Document>.self, from: data)

            guard decoded.count > 0, !decoded.results.isEmpty else {
                // this means the ASN was not found
                Logger.api.notice("Got empty document result (ASN not found)")
                return nil
            }
            return decoded.results.first

        } catch {
            Logger.api.error("Error fetching document by ASN \(asn): \(error)")
            return nil
        }
    }

    private func nextAsnCompatibility() async -> UInt {
        Logger.api.notice("Getting next ASN with legacy compatibility method")
        var fs = FilterState()
        fs.sortField = .asn
        fs.sortOrder = .descending
        let endpoint = Endpoint.documents(page: 1, filter: fs, pageSize: 1)
        let url = url(endpoint)
        Logger.api.notice("\(url)")

        let request = request(endpoint)

        do {
            let (data, res) = try await URLSession.shared.data(for: request)
            guard (res as? HTTPURLResponse)?.statusCode == 200 else {
                Logger.shared.error("Error fetching document for next ASN: status code != 200. \(String(decoding: data, as: UTF8.self))")
                return 0
            }

            let decoded = try decoder.decode(ListResponse<Document>.self, from: data)

            return (decoded.results.first?.asn ?? 0) + 1
        } catch {
            Logger.api.error("Error fetching document for next ASN: \(error)")
        }

        return 0
    }

    private func nextAsnDirectEndpoint() async -> UInt {
        Logger.api.notice("Getting next ASN with dedicated endpoint")
        let request = request(.nextAsn())

        do {
            let (data, res) = try await URLSession.shared.data(for: request)
            let code = (res as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                Logger.shared.error("Error fetching next ASN: status code \(code) != 200")
                return 0
            }

            let asn = try decoder.decode(UInt.self, from: data)
            Logger.api.notice("Have next ASN \(asn)")
            return asn
        } catch {
            Logger.api.error("Error fetching next ASN: \(error)")
            return 0
        }
    }

    func nextAsn() async -> UInt {
        if apiVersion == nil || backendVersion == nil {
            await ensureBackendVersions()
        }

        if let backendVersion, backendVersion >= (2, 0, 0) {
            return await nextAsnDirectEndpoint()
        } else {
            return await nextAsnCompatibility()
        }
    }

    func users() async -> [User] { await all(User.self) }

    func thumbnail(document: Document) async -> Image? {
        guard let data = await thumbnailData(document: document) else {
            Logger.api.error("Did not get thumbnail data")
            return nil
        }
        guard let uiImage = UIImage(data: data) else {
            Logger.api.error("Thumbnail data did not decode as image")
            return nil
        }
        let image = Image(uiImage: uiImage)
        return image
    }

    func thumbnailData(document: Document) async -> Data? {
        Logger.api.notice("Get thumbnail")
        let url = url(Endpoint.thumbnail(documentId: document.id))

        var request = URLRequest(url: url)
        request.setValue("Token \(apiToken)", forHTTPHeaderField: "Authorization")
        connection.extraHeaders.apply(toRequest: &request)

        do {
            let (data, res) = try await URLSession.shared.data(for: request)

            guard (res as? HTTPURLResponse)?.statusCode == 200 else {
                Logger.shared.error("Status code for thumbnail data was not 200: \(res)")
                return nil
            }

            return data
        } catch {
            Logger.api.error("Error getting thumbnail data for document: \(error)")
            return nil
        }
    }

    func suggestions(documentId: UInt) async -> Suggestions {
        Logger.api.notice("Get suggestions")
        let request = request(.suggestions(documentId: documentId))

        do {
            let (data, res) = try await URLSession.shared.data(for: request)

            guard (res as? HTTPURLResponse)?.statusCode == 200 else {
                throw CrudApiError(operation: .read, type: [PaperlessTask].self, status: nil)
            }

            return try decoder.decode(Suggestions.self, from: data)
        } catch {
            Logger.api.error("Unable to load suggestions: \(error)")
            return .init()
        }
    }

    // MARK: Saved views

    func savedViews() async -> [SavedView] {
        await all(SavedView.self)
    }

    func create(savedView view: ProtoSavedView) async throws -> SavedView {
        try await create(element: view, endpoint: .createSavedView(), returns: SavedView.self)
    }

    func update(savedView view: SavedView) async throws -> SavedView {
        try await update(element: view, endpoint: .savedView(id: view.id))
    }

    func delete(savedView view: SavedView) async throws {
        try await delete(element: view, endpoint: .savedView(id: view.id))
    }

    // MARK: Storage paths

    func storagePaths() async -> [StoragePath] {
        await all(StoragePath.self)
    }

    func create(storagePath: ProtoStoragePath) async throws -> StoragePath {
        try await create(element: storagePath, endpoint: .createStoragePath(), returns: StoragePath.self)
    }

    func update(storagePath: StoragePath) async throws -> StoragePath {
        try await update(element: storagePath, endpoint: .savedView(id: storagePath.id))
    }

    func delete(storagePath: StoragePath) async throws {
        try await delete(element: storagePath, endpoint: .storagePath(id: storagePath.id))
    }

    private struct UiSettingsResponse: Codable {
        var user: User
    }

    func currentUser() async throws -> User {
        let request = request(.uiSettings())

        let (data, res) = try await URLSession.shared.data(for: request)

        guard (res as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "No body"
            throw CrudApiError(operation: .read, type: UiSettingsResponse.self, status: (res as? HTTPURLResponse)?.statusCode, body: body)
        }

        let uiSettings = try decoder.decode(UiSettingsResponse.self, from: data)
        return uiSettings.user
    }

    func tasks() async -> [PaperlessTask] {
        let request = request(.tasks())

        do {
            let (data, res) = try await URLSession.shared.data(for: request)

            guard (res as? HTTPURLResponse)?.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "No body"
                throw CrudApiError(operation: .read, type: [PaperlessTask].self, status: (res as? HTTPURLResponse)?.statusCode, body: body)
            }

            return try decoder.decode([PaperlessTask].self, from: data)
        } catch {
            Logger.api.error("Unable to load tasks: \(error)")
            return []
        }
    }

    private func ensureBackendVersions() async {
        Logger.api.notice("Getting backend versions")
        let request = request(.root())
        do {
            let (data, res) = try await URLSession.shared.data(for: request)

            guard let res = res as? HTTPURLResponse else {
                Logger.api.error("Unable to get API and backend version: Not an HTTP response")
                return
            }

            let code: Int? = res.statusCode

            guard code == 200 else {
                Logger.shared.error("Unable to get API and backend version: status code: \(code ?? 0), \(data)")
                return
            }

            let backend1 = res.value(forHTTPHeaderField: "X-Version")
            let backend2 = res.value(forHTTPHeaderField: "x-version")

            guard let backend1, let backend2 else {
                Logger.api.error("Unable to get API and backend version: X-Version not found")
                return
            }
            let backend = [backend1, backend2].compactMap { $0 }.first!

            let parts = backend.components(separatedBy: ".").compactMap { UInt($0) }
            guard parts.count == 3 else {
                Logger.api.error("Unable to get API and backend version: Invalid format \(backend)")
                return
            }

            let backendVersion = (parts[0], parts[1], parts[2])

            guard let apiVersion = res.value(forHTTPHeaderField: "X-Api-Version"), let apiVersion = UInt(apiVersion) else {
                Logger.api.error("Unable to get API and backend version: X-Api-Version not found")
                return
            }

            self.apiVersion = apiVersion
            self.backendVersion = backendVersion

        } catch {
            Logger.api.error("Unable to get API and backend version, error: \(error)")
            return
        }
    }
}
