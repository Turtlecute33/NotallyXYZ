import NotallyCore
import SwiftUI

/// First start: choose the server, then create an account or connect with an existing key.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var server = ""
    @State private var mode = 0
    @State private var invite = ""
    @State private var keyText = ""
    @State private var busy = false
    @State private var error: String?
    @State private var newKeys: SyncKeys?
    @State private var saved = false

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
            Text("NotallyXYZ").font(.largeTitle.weight(.medium))
            Text("End-to-end encrypted notes. Your server stores only ciphertext.")
                .foregroundStyle(.secondary)

            if let keys = newKeys {
                keyConfirmation(keys)
            } else {
                form
            }
        }
        .padding(40)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if server.isEmpty { server = model.serverURL } }
    }

    private var form: some View {
        Form {
            TextField("Server", text: $server, prompt: Text("https://notes.example.com"))
            Picker("", selection: $mode) {
                Text("Connect with sync key").tag(0)
                Text("Create account").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if mode == 0 {
                TextField("Sync key", text: $keyText, prompt: Text("XXXX-XXXX-…"), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...3)
            } else {
                SecureField("Invite token", text: $invite, prompt: Text("SIGNUP_TOKEN of the server"))
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(mode == 0 ? "Connect" : "Create Account", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || server.isEmpty || (mode == 0 ? keyText.isEmpty : invite.isEmpty))
            }
        }
        .formStyle(.grouped)
    }

    private func keyConfirmation(_ keys: SyncKeys) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Save your sync key now", systemImage: "key.fill").font(.headline)
            Text("It unlocks your notes on every device. The server cannot recover it. If you lose the key and all your devices, your notes are lost.")
                .fixedSize(horizontal: false, vertical: true)
            KeyBox(text: keys.display)
            Toggle("I stored the key in a safe place (for example a password manager)", isOn: $saved)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Continue") {
                    guard let url = APIClient.validate(server) else { return }
                    do { try model.finishSetup(server: url, keys: keys) } catch { self.error = "Could not store the key in the Keychain." }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!saved)
            }
        }
        .padding(20)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func submit() {
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                if mode == 0 {
                    try await model.connect(server: server, keyText: keyText)
                } else {
                    newKeys = try await model.createAccount(server: server, invite: invite)
                }
            } catch let e as KeyError {
                error = e == .checksumMismatch ? "The key has a typo (checksum does not match)." : "This is not a valid sync key."
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// Shows a secret in monospace with a copy button. The clipboard entry is marked concealed.
struct KeyBox: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                copied = true
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
