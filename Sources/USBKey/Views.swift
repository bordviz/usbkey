import SwiftUI
import AppKit
import KeyCore

struct ErrorNotice: ViewModifier {
    @ObservedObject var model: Model
    func body(content: Content) -> some View {
        content.alert("USBKey", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
struct KeyPicker: View {
    @ObservedObject var model: Model
    var body: some View {
        Menu {
            ForEach(model.records) { entry in Button(entry.name + " · " + entry.id.uuidString.prefix(8)) { model.selectedKey = entry.id; model.refresh() } }
            if model.records.isEmpty { Text("Нет зарегистрированных USB-ключей") }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive").foregroundStyle(Brand.muted)
                Text(model.record?.name ?? "Выберите USB-ключ").font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.muted)
            }.foregroundStyle(Brand.ink).padding(.horizontal, 13).padding(.vertical, 10)
                .background(Brand.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.line))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}
struct StatusView: View {
    @ObservedObject var model: Model
    let typeValue: () -> Void
    let openMain: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("USBKey").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(model.typingRecord?.name ?? "Личный USB-ключ").font(.system(size: 11)).foregroundStyle(Brand.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                Circle().fill(model.typingRecord != nil ? Color.green : Brand.muted).frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(model.typingRecord != nil ? "Ключ подключён" : "Подключите USB-ключ").font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(model.typingRecord != nil ? "Выберите поле в нужном приложении,\nзатем нажмите «Ввести»." : "Пароли и токены остаются\nна вашем носителе.")
                    .font(.system(size: 12)).foregroundStyle(Brand.muted).lineSpacing(3)
            }
            Button(action: typeValue) {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill").font(.system(size: 19, weight: .medium))
                    Text(model.busy ? "Подождите…" : "Ввести").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if model.shortcutEnabled { Text(model.shortcut.label).font(.system(size: 11, weight: .medium, design: .monospaced)).opacity(0.7) }
                    else { Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).opacity(0.65) }
                }.frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(ActionStyle(kind: .primary)).disabled(model.typingRecord == nil || model.busy)
            if !model.typingMessage.isEmpty {
                Text(model.typingMessage).font(.system(size: 11)).foregroundStyle(model.typingFailed ? Color(red: 1, green: 0.6, blue: 0.55) : Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 5) { Image(systemName: "keyboard"); Text("Набор в поле • без буфера обмена") }.font(.system(size: 10)).foregroundStyle(Brand.muted)
            }
            Button { Task { await model.ejectVolume() } } label: {
                HStack(spacing: 9) {
                    Image(systemName: "eject")
                    Text("Извлечь")
                    Spacer()
                    if let volume = model.ejectableVolume { Text(volume.name).font(.system(size: 10)).foregroundStyle(Brand.muted).lineLimit(1) }
                }.frame(maxWidth: .infinity)
            }.buttonStyle(ActionStyle(kind: .quiet)).disabled(model.ejectableVolume == nil || model.busy)
            Rectangle().fill(Brand.line).frame(height: 1)
            HStack(spacing: 10) {
                Button(action: openMain) { Label("Настроить", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity) }.buttonStyle(ActionStyle(kind: .quiet))
                Button { NSApp.terminate(nil) } label: { Label("Выйти", systemImage: "power").frame(maxWidth: .infinity) }.buttonStyle(ActionStyle(kind: .quiet))
            }
        }.padding(22).frame(width: 350).foregroundStyle(Brand.ink)
            .background(Brand.sidebar, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Brand.line))
            .preferredColorScheme(.dark)
    }
}
private enum Page: String, CaseIterable {
    case vault = "Хранилище", ssh = "SSH-доступ", git = "Подписи Git", device = "Устройство"
    var icon: String { switch self { case .vault: return "square.stack.3d.up"; case .ssh: return "terminal"; case .git: return "point.3.connected.trianglepath.dotted"; case .device: return "slider.horizontal.3" } }
    var subtitle: String { switch self { case .vault: return "Пароли, токены и ключи под вашим контролем."; case .ssh: return "Подключение к серверам без экспорта закрытого ключа."; case .git: return "Подписи, которые подтверждаете вы."; case .device: return "Носитель, клавиатурный ввод и сочетание клавиш." } }
}
struct MainView: View {
    @ObservedObject var model: Model
    let restartApp: () -> Void
    @State private var page = Page.vault
    @State private var showCreate = false
    @State private var showAdd = false
    @State private var consent = false
    @State private var deleteEntry = false
    @State private var guide: SetupTopic?
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Brand.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(page.rawValue).font(.system(size: 29, weight: .bold, design: .rounded))
                        Text(page.subtitle).font(.system(size: 12)).foregroundStyle(Brand.muted)
                        Button { guide = SetupTopic(rawValue: page.rawValue) } label: {
                            Label("Как настроить", systemImage: "questionmark.circle")
                        }.buttonStyle(ActionStyle(kind: .quiet))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 9) { KeyPicker(model: model); ConnectionBadge(connected: model.connected) }
                }.padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 24)
                Rectangle().fill(Brand.line).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch page {
                        case .vault: vaultPage
                        case .ssh: sshPage
                        case .git: gitPage
                        case .device: devicePage
                        }
                    }.padding(28)
                }
                if !model.message.isEmpty {
                    HStack(alignment: .top, spacing: 8) { Image(systemName: "info.circle"); Text(model.message).textSelection(.enabled) }
                        .font(.system(size: 11)).foregroundStyle(Brand.muted).padding(.horizontal, 28).padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Brand.sidebar)
                }
            }
        }.frame(minWidth: 1080, minHeight: 680).background(Brand.canvas).foregroundStyle(Brand.ink)
            .preferredColorScheme(.dark).tint(Brand.red).modifier(ErrorNotice(model: model))
            .sheet(item: $guide) { topic in
                SetupGuide(topic: topic, publicKey: model.record?.publicKey, socketPath: model.socketPath)
            }
            .sheet(isPresented: $showAdd) { AddSecretView(model: model) }
            .sheet(isPresented: $showCreate) { createSheet }
            .alert("Удалить выбранную запись?", isPresented: $deleteEntry) {
                Button("Отмена", role: .cancel) {}
                Button("Удалить", role: .destructive) { Task { await model.deleteSelected() } }
            } message: { Text("Восстановления записи нет. Сначала сохраните нужные данные в надёжном месте.") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 45, height: 45)
                VStack(alignment: .leading, spacing: 3) {
                    Text("USBKey").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("ВАШ ЛИЧНЫЙ КЛЮЧ").font(.system(size: 8, weight: .medium)).tracking(1.2).foregroundStyle(Brand.muted)
                }
            }.padding(.top, 28).padding(.bottom, 38)
            ForEach(Page.allCases, id: \.self) { item in
                Button { page = item } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.icon).font(.system(size: 15, weight: .medium)).frame(width: 22)
                        Text(item.rawValue).font(.system(size: 13, weight: page == item ? .semibold : .regular))
                        Spacer()
                        if page == item { RoundedRectangle(cornerRadius: 2).fill(Brand.red).frame(width: 3, height: 18) }
                    }.padding(.horizontal, 13).padding(.vertical, 14)
                        .foregroundStyle(page == item ? Brand.ink : Brand.muted)
                        .background(page == item ? Color.white.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).padding(.bottom, 7)
            }
            Spacer()
            Rectangle().fill(Brand.line).frame(height: 1).padding(.bottom, 20)
            Label("Хранится на флешке", systemImage: "lock.shield").font(.system(size: 11, weight: .medium))
            Text("Секреты зашифрованы.\nДоступ подтверждается вами.").font(.system(size: 10)).foregroundStyle(Brand.muted).lineSpacing(4).padding(.top, 8)
            Text("USBKey " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(Brand.muted.opacity(0.6)).padding(.top, 26).padding(.bottom, 26)
        }.padding(.horizontal, 18).frame(width: 224).frame(maxHeight: .infinity).background(Brand.sidebar)
    }
    private var vaultPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Surface {
                HStack(alignment: .top, spacing: 15) {
                    Image(systemName: "key.fill").font(.system(size: 22)).foregroundStyle(.white).frame(width: 48, height: 48)
                        .background(Brand.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ДЛЯ КНОПКИ «ВВЕСТИ»").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(Brand.muted)
                        Text(model.typingSummary?.name ?? (model.vaultLoaded ? "Запись не назначена" : "Откройте записи флешки"))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text("Выберите запись ниже и назначьте её для ввода. Привязка сохранится на этой флешке.")
                            .font(.system(size: 11)).foregroundStyle(Brand.muted).lineSpacing(3)
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack {
                Text("Записи").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(model.vaultLoaded ? String(model.summaries.count) : "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(Brand.muted)
                Spacer()
                Button { Task { await model.loadSecrets() } } label: { Label(model.vaultLoaded ? "Обновить" : "Открыть", systemImage: "lock.open") }
                    .buttonStyle(ActionStyle()).disabled(!model.connected || model.busy)
                Button { showAdd = true } label: { Label("Добавить", systemImage: "plus") }.buttonStyle(ActionStyle(kind: .primary)).disabled(!model.connected || model.busy)
            }
            if model.summaries.isEmpty {
                Surface {
                    VStack(spacing: 13) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 30, weight: .light)).foregroundStyle(Brand.muted).padding(.top, 24)
                        Text(model.vaultLoaded ? "Место для ваших секретов" : "Ваши записи скрыты").font(.system(size: 17, weight: .medium, design: .rounded))
                        Text(model.vaultLoaded ? "Добавьте пароль, токен или отдельный SSH-ключ." : "Подключите флешку и подтвердите доступ,\nчтобы увидеть сохранённые записи.")
                            .font(.system(size: 12)).foregroundStyle(Brand.muted).multilineTextAlignment(.center).lineSpacing(4).padding(.bottom, 28)
                    }.frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 8) { ForEach(model.summaries) { entry in secretRow(entry) } }
            }
            if let entry = model.selectedSummary {
                Surface {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack { Text(entry.name).font(.system(size: 16, weight: .semibold)); Spacer(); Text(entry.kind.title).font(.system(size: 11)).foregroundStyle(Brand.muted) }
                        if let key = entry.publicKey {
                            code(key)
                            Button("Скопировать открытый ключ") { model.copyPublic(key) }.buttonStyle(ActionStyle())
                        } else {
                            Text("Кнопка в строке состояния и глобальная комбинация будут набирать это значение в активном поле другого приложения.")
                                .font(.system(size: 12)).foregroundStyle(Brand.muted).lineSpacing(4)
                            Button { Task { await model.setTypingDefault() } } label: {
                                Label(model.typingEntryID == entry.id ? "Назначена для ввода" : "Назначить для «Ввести»", systemImage: model.typingEntryID == entry.id ? "checkmark" : "key.fill")
                            }.buttonStyle(ActionStyle(kind: .primary)).disabled(model.busy || !model.connected || model.typingEntryID == entry.id)
                        }
                        Button("Удалить запись…", role: .destructive) { deleteEntry = true }.buttonStyle(ActionStyle(kind: .danger)).disabled(model.busy || !model.connected)
                    }
                }
            }
        }
    }
    private func secretRow(_ entry: SecretSummary) -> some View {
        Button { model.selectedSecret = entry.id } label: {
            HStack(spacing: 14) {
                Image(systemName: entry.kind == .sshKey ? "terminal" : (entry.kind == .password ? "lock" : "text.alignleft"))
                    .font(.system(size: 16)).foregroundStyle(Brand.muted).frame(width: 38, height: 38)
                    .background(Brand.canvas, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) { Text(entry.name).font(.system(size: 13, weight: .medium)); Text(entry.kind.title).font(.system(size: 10)).foregroundStyle(Brand.muted) }
                Spacer()
                if model.typingEntryID == entry.id { Label("Для ввода", systemImage: "key.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8)).padding(8).background(Brand.red.opacity(0.4), in: Capsule()) }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.muted)
            }.padding(13).foregroundStyle(Brand.ink).background(model.selectedSecret == entry.id ? Brand.raised : Brand.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(model.selectedSecret == entry.id ? Brand.red.opacity(0.8) : Brand.line))
        }.buttonStyle(.plain)
    }
    private var sshPage: some View {
        VStack(spacing: 18) {
            Surface {
                VStack(alignment: .leading, spacing: 16) {
                    Label(model.agentStatus, systemImage: "network").font(.system(size: 16, weight: .semibold))
                    bodyText("SSH-клиент получает подпись, а закрытый ключ остаётся внутри USBKey. Каждая новая аутентификация требует флешку и ваше подтверждение.")
                    bodyText("Создайте отдельный SSH-ключ в хранилище или используйте основной ключ носителя. Добавьте открытый ключ в ~/.ssh/authorized_keys на сервере.")
                    Button("Скопировать основной открытый ключ") { model.copyPublic(model.record?.publicKey) }.buttonStyle(ActionStyle()).disabled(model.record == nil)
                }
            }
            Surface {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Подключение к серверу").font(.system(size: 16, weight: .semibold, design: .rounded))
                    code(model.sshExample)
                    bodyText("Или добавьте в нужный Host-блок ~/.ssh/config:")
                    code("IdentityAgent \"\(model.socketPath)\"\nForwardAgent no")
                    bodyText("Поддерживается Ed25519. Импорт — OpenSSH без парольного шифрования. Агент не удостоверяет имя сервера: проверяйте host fingerprint в SSH-клиенте.")
                }
            }
        }
    }
    private var gitPage: some View {
        VStack(spacing: 18) {
            Surface {
                VStack(alignment: .leading, spacing: 17) {
                    Text("Подпись коммитов").font(.system(size: 17, weight: .semibold, design: .rounded))
                    bodyText("Подключите репозиторий, чтобы подписывать коммиты ключом с флешки. Перед подписью появится окно с содержимым Git-объекта.")
                    if let record = model.record { code(SSHSignature.fingerprint(record.publicKey)) }
                    HStack {
                        Button("Выбрать репозиторий…") { model.configure() }.buttonStyle(ActionStyle(kind: .primary)).disabled(!model.connected)
                        Button("Открытый signing key") { model.copyPublic(model.record?.publicKey) }.buttonStyle(ActionStyle()).disabled(model.record == nil)
                    }
                    bodyText("Меняются только локальные настройки выбранного репозитория. Для GitHub/GitLab добавьте этот ключ как signing key.")
                }
            }
        }
    }
    private var devicePage: some View {
        VStack(spacing: 18) {
            Surface {
                VStack(alignment: .leading, spacing: 15) {
                    HStack { Label("Клавиатурный ввод", systemImage: "keyboard").font(.system(size: 16, weight: .semibold)); Spacer(); Image(systemName: model.keyboardPermission ? "checkmark.seal.fill" : "exclamationmark.circle").foregroundStyle(model.keyboardPermission ? .green : .orange) }
                    bodyText("USBKey набирает значение в поле другого приложения. Для этого macOS должна разрешить приложению «Универсальный доступ». Разрешение выдаётся вручную в настройках системы.")
                    Button(model.keyboardPermission ? "Открыть разрешения macOS" : "Разрешить клавиатурный ввод…") { model.openKeyboardPermissions() }.buttonStyle(ActionStyle(kind: model.keyboardPermission ? .secondary : .primary))
                    bodyText("Ввод работает через клавиатурные события, включая терминалы и редакторы без стандартного поля Accessibility. Буфер обмена не используется. При переключении в другое приложение набор останавливается. Enter и Tab не отправляются.")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Отправка клавиатуры: " + (model.keyboardPermission ? "разрешена" : "не разрешена этой копии"))
                        Text("Accessibility: " + (model.accessibilityPermission ? "подтверждён" : "не подтверждён"))
                        Text("Запущено: " + Bundle.main.bundleURL.path).textSelection(.enabled)
                    }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.muted)
                    HStack {
                        Button("Показать эту копию в Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }.buttonStyle(ActionStyle())
                        Button("Обновить статус") { model.refresh() }.buttonStyle(ActionStyle())
                        Button("Перезапустить", action: restartApp).buttonStyle(ActionStyle())
                    }
                    if !model.keyboardPermission {
                        bodyText("Если переключатель USBKey уже включён: завершите все копии USBKey, удалите старую строку кнопкой «−» и добавьте через «+» именно /Applications/USBKey.app. Затем запустите приложение заново. Старое разрешение могло относиться к предыдущей подписи.")
                    }
                    Rectangle().fill(Brand.line).frame(height: 1)
                    Toggle("Подтверждать каждый ввод через Touch ID / пароль", isOn: $model.confirmEveryTyping)
                        .toggleStyle(.switch).font(.system(size: 12))
                    bodyText(model.confirmEveryTyping ? "Перед вводом macOS запрашивает подтверждение владельца." : "Ввод выполняется сразу с подключённой флешкой. Любой пользователь вашего разблокированного сеанса сможет нажать «Ввести» или сочетание клавиш. Запросы доступа самой Связки ключей возможны отдельно.")

                }
            }
            Surface {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("Глобальная комбинация", systemImage: "command").font(.system(size: 16, weight: .semibold))
                        Spacer(); Toggle("Включить", isOn: $model.shortcutEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    bodyText("Нажмите на сочетание и запишите своё. Оно вводит назначенную запись флешки без открытия меню.")
                    ShortcutRecorder(shortcut: $model.shortcut, recording: $model.shortcutRecording, onError: { model.error = $0 })
                        .frame(height: 44).frame(maxWidth: .infinity).background(Brand.canvas, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(model.shortcutRecording ? Brand.red : Brand.line))
                    Text(model.shortcutStatus).font(.system(size: 11)).foregroundStyle(Brand.muted)
                }
            }
            Surface {
                VStack(alignment: .leading, spacing: 16) {
                    Label("USB-носитель", systemImage: "externaldrive").font(.system(size: 16, weight: .semibold))
                    if model.volumes.isEmpty { bodyText("Подключите USB-флешку с доступом на запись.") }
                    else {
                        Menu {
                            ForEach(model.volumes) { item in Button(item.name) { model.selectedVolume = item.id } }
                        } label: { HStack { Text(model.volumes.first(where: { $0.id == model.selectedVolume })?.name ?? "Выберите носитель"); Spacer(); Image(systemName: "chevron.down") }.modifier(FieldStyle()) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        if let volume = model.volumes.first(where: { $0.id == model.selectedVolume }) { bodyText(volume.binding.serialHash == nil ? "Серийный номер недоступен: привязка по UUID и Keychain этого Mac." : "Привязка по UUID, серийному номеру USB и Keychain этого Mac.") }
                    }
                    Button("Подготовить новый USB-ключ…") { showCreate = true }.buttonStyle(ActionStyle()).disabled(model.volumes.isEmpty || model.busy)
                    Toggle("Запускать в строке состояния при входе в macOS", isOn: $model.launchAtLogin).toggleStyle(.switch).font(.system(size: 12))
                }
            }
            Surface {
                bodyText("USBKey работает после входа в macOS и не разблокирует FileVault или экран входа. Обычная флешка не обладает аппаратной некопируемостью: её идентификаторы можно подделать. Для расшифровки также нужен секрет из Keychain этого Mac.")
            }
        }
    }
    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Новый USB-ключ").font(.system(size: 24, weight: .bold, design: .rounded))
            bodyText("В корне выбранной флешки появится зашифрованный токен. Другие файлы не изменятся. Ключ расшифровки останется в Keychain этого Mac.")
            bodyText("Потеря флешки или записи Keychain приведёт к потере сохранённых секретов. Это программный ключ, а не аппаратный токен с защищённым чипом.")
            Toggle("Понимаю привязку к этому Mac и ограничения", isOn: $consent).font(.system(size: 12))
            HStack { Spacer(); Button("Отмена") { showCreate = false }.buttonStyle(ActionStyle()); Button("Создать ключ") { showCreate = false; model.create() }.buttonStyle(ActionStyle(kind: .primary)).disabled(!consent) }
        }.padding(30).frame(width: 550).background(Brand.sidebar).foregroundStyle(Brand.ink).preferredColorScheme(.dark)
    }
    private func bodyText(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(Brand.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true) }
    private func code(_ value: String) -> some View { CopyableCommand(title: "Команда / открытые данные", value: value) }
}
struct AddSecretView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = SecretKind.token
    @State private var value = ""
    @State private var generate = true
    @State private var multiline = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Новая запись").font(.system(size: 25, weight: .bold, design: .rounded)); Spacer(); Image(systemName: "lock.doc").font(.system(size: 24, weight: .light)).foregroundStyle(Brand.muted) }
            Text("Сохранится в зашифрованном виде на выбранной флешке.").font(.system(size: 12)).foregroundStyle(Brand.muted)
            TextField("Название записи", text: $name).modifier(FieldStyle())
            HStack(spacing: 7) { ForEach(SecretKind.allCases, id: \.self) { item in
                Button { kind = item } label: { Text(item.title).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 11).background(kind == item ? Brand.red : Brand.canvas, in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain)
            } }
            if kind == .sshKey {
                Toggle("Сгенерировать новый Ed25519", isOn: $generate).font(.system(size: 12))
                if !generate { Button("Импортировать файл OpenSSH…", action: importKey).buttonStyle(ActionStyle()) }
            }
            if kind != .sshKey || !generate {
                if kind == .sshKey || multiline {
                    TextEditor(text: $value).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(10).frame(height: 150)
                        .background(Brand.canvas, in: RoundedRectangle(cornerRadius: 11)).privacySensitive()
                } else { SecureField("Пароль или токен", text: $value).modifier(FieldStyle()).privacySensitive() }
                if kind != .sshKey { Toggle("Многострочный текст — показывать при вводе", isOn: $multiline).font(.system(size: 11)) }
            }
            Text("Для кнопки «Ввести» подходят однострочные пароли и токены. SSH-ключи используются агентом и не набираются в поле.").font(.system(size: 11)).foregroundStyle(Brand.muted).lineSpacing(3)
            HStack {
                Spacer(); Button("Отмена") { value = ""; dismiss() }.buttonStyle(ActionStyle()).disabled(model.busy)
                Button("Сохранить на флешку") { Task { if await model.saveSecret(name: name, kind: kind, value: value, generate: generate) { value = ""; dismiss() } } }
                    .buttonStyle(ActionStyle(kind: .primary)).disabled(model.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (value.isEmpty && !(kind == .sshKey && generate)))
            }.padding(.top, 6)
        }.padding(30).frame(width: 580).background(Brand.sidebar).foregroundStyle(Brand.ink).preferredColorScheme(.dark).tint(Brand.red)
            .modifier(ErrorNotice(model: model)).onDisappear { value = "" }
    }
    private func importKey() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.prompt = "Импортировать"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 65_536 else { throw KeyError("Файл слишком большой.") }
            let text = try String(contentsOf: url, encoding: .utf8); _ = try OpenSSHKey.decode(text); value = text
            if name.isEmpty { name = url.lastPathComponent }
        } catch { model.error = error.localizedDescription }
    }
}
