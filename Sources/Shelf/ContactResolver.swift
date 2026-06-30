import Contacts
import Foundation

final class ContactResolver {
    private let store = CNContactStore()

    private var keys: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]
    }

    var permissionState: PermissionState {
        CNContactStore.contactsPermissionState()
    }

    func requestAccessIfNeeded() async -> PermissionState {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else {
            return permissionState
        }

        return await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { _, _ in
                continuation.resume(returning: CNContactStore.contactsPermissionState())
            }
        }
    }

    func contacts(for hint: AppHint) -> [ContactClue] {
        guard permissionState == .allowed else {
            return []
        }

        switch hint.kind {
        case .contact:
            if let contactIdentifier = hint.contactIdentifier,
               let contact = contact(withIdentifier: contactIdentifier) {
                return [clue(from: contact)]
            }
        case .email:
            if let email = hint.email ?? EmailAddress.first(in: hint.value) {
                return contacts(matchingEmail: email)
            }
        case .url:
            if let url = hint.url {
                return contacts(matchingURL: url)
            }
        case .name, .window:
            return contacts(matchingName: hint.title)
        case .file, .unknown:
            break
        }

        if let email = EmailAddress.first(in: hint.value) {
            return contacts(matchingEmail: email)
        }
        if let url = hint.url {
            return contacts(matchingURL: url)
        }
        return contacts(matchingName: hint.title)
    }

    private func contact(withIdentifier identifier: String) -> CNContact? {
        try? store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
    }

    private func contacts(matchingEmail email: String) -> [ContactClue] {
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
        let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        return contacts.map(clue)
    }

    private func contacts(matchingName name: String) -> [ContactClue] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else {
            return []
        }
        let predicate = CNContact.predicateForContacts(matchingName: trimmed)
        let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        return contacts.map(clue)
    }

    private func contacts(matchingURL url: URL) -> [ContactClue] {
        let needle = URLNormalizer.normalized(url.absoluteString)
        guard !needle.isEmpty else {
            return []
        }

        var matches: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, _ in
            let urls = contact.urlAddresses.map { URLNormalizer.normalized($0.value as String) }
            if urls.contains(where: { urlMatches(needle: needle, candidate: $0) }) {
                matches.append(contact)
            }
        }
        return matches.map(clue)
    }

    private func urlMatches(needle: String, candidate: String) -> Bool {
        needle == candidate
            || needle.hasPrefix(candidate + "/")
            || candidate.hasPrefix(needle + "/")
    }

    private func clue(from contact: CNContact) -> ContactClue {
        let formattedName = CNContactFormatter.string(from: contact, style: .fullName)
        let displayName = formattedName?.isEmpty == false
            ? formattedName!
            : contact.organizationName

        return ContactClue(
            id: contact.identifier,
            displayName: displayName.isEmpty ? "Unnamed Contact" : displayName,
            organization: contact.organizationName,
            emails: contact.emailAddresses.map { String($0.value).lowercased() },
            urls: contact.urlAddresses.compactMap { URL(string: $0.value as String) },
            phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue },
            imageData: contact.imageData
        )
    }
}
