import SwiftUI
import AppKit

// Guides only display public information; commands are copied, never executed.
enum SetupTopic: String, Identifiable {
    case vault = "Хранилище", ssh = "SSH-доступ", git = "Подписи Git", device = "Устройство"
    var id: String { rawValue }
}

struct CopyableCommand: View {
    let title: String
    let value: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Brand.muted)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain).accessibilityLabel("Копировать: " + title)
            }
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).background(Brand.canvas, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Brand.line))
            .onChange(of: value) { _ in copied = false }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { copied = false }
            }
    }
}

struct SetupGuide: View {
    let topic: SetupTopic
    let publicKey: String?
    let socketPath: String
    @Environment(\.dismiss) private var dismiss
    private var shellSocket: String { "'" + socketPath.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "book.closed").font(.system(size: 24)).foregroundStyle(Brand.red)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Настройка · " + topic.rawValue).font(.system(size: 23, weight: .bold, design: .rounded))
                    Text("Пошаговая инструкция").font(.system(size: 12)).foregroundStyle(Brand.muted)
                }
                Spacer()
                Button("Готово") { dismiss() }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
            }.padding(24)
            Rectangle().fill(Brand.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch topic {
                    case .git: gitGuide
                    case .ssh: sshGuide
                    case .vault: vaultGuide
                    case .device: deviceGuide
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(width: 740, height: 660).background(Brand.sidebar).foregroundStyle(Brand.ink)
            .preferredColorScheme(.dark).tint(Brand.red)
    }
    private func step(_ number: Int, _ title: String, _ text: String) -> some View {
        Surface {
            HStack(alignment: .top, spacing: 13) {
                Text(String(number)).font(.system(size: 12, weight: .bold, design: .monospaced))
                    .frame(width: 28, height: 28).background(Brand.red.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                    note(text)
                }
            }
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Brand.muted).lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var keyBlock: some View {
        if let publicKey {
            CopyableCommand(title: "Основной открытый ключ выбранной флешки", value: publicKey)
        } else {
            note("Сначала подготовьте или выберите USB-ключ в основном окне. Здесь появится его открытый ключ.")
        }
    }
    private var gitGuide: some View {
        Group {
            step(1, "Подключите флешку", "Выберите свой USB-ключ вверху основного окна. Для Git используется основной ключ носителя, независимо от записи, назначенной для «Ввести».")
            step(2, "Укажите автора в репозитории", "Откройте Терминал в папке нужного репозитория. Замените имя и почту в примере на свои. Для GitHub используйте подтверждённую почту аккаунта или его адрес noreply.")
            CopyableCommand(title: "Выполнить в папке репозитория", value: "git config --local user.name \"Ваше имя\"\ngit config --local user.email \"you@example.com\"")
            step(3, "Подключите репозиторий в USBKey", "Закройте инструкцию и нажмите «Выбрать репозиторий…» в разделе «Подписи Git». Приложение само настроит SSH-подписи, помощник USBKey, открытый ключ и allowed_signers только для этой папки. Повторите для каждого репозитория.")
            step(4, "Добавьте signing key на GitHub / GitLab", "Скопируйте открытый ключ ниже. На GitHub: Settings → SSH and GPG keys → New SSH key → Key type: Signing Key. В GitLab добавьте SSH-ключ с назначением Signing или Authentication & Signing. Назначение только Authentication не подтверждает подписи коммитов.")
            keyBlock
            step(5, "Подпишите коммит", "Сначала подготовьте нужные изменения через git add. Следующая команда создаёт коммит из подготовленных изменений. Подключите флешку и подтвердите запрос USBKey. После настройки подпись включена и для обычного git commit.")
            CopyableCommand(title: "Создать подписанный коммит", value: "git commit -S -m \"Описание изменений\"")
            CopyableCommand(title: "Проверить последнюю подпись локально", value: "git log -1 --show-signature\ngit verify-commit HEAD")
            note("Ожидаемый результат — Good \"git\" signature. На сайте отметка Verified появится после push, если ключ и почта привязаны корректно. Подпись не заменяет авторизацию для push. Старые коммиты не меняются.")
            CopyableCommand(title: "Посмотреть локальные параметры", value: "git config --local --get gpg.format\ngit config --local --get gpg.ssh.program\ngit config --local --get user.signingkey\ngit config --local --get gpg.ssh.allowedSignersFile\ngit config --local --get commit.gpgsign")
            note("Если подпись не создаётся: проверьте флешку, правильный репозиторий и установленную копию /Applications/USBKey.app. Если сменили user.email, снова подключите репозиторий в USBKey для обновления allowed_signers. SSH-подписи требуют Git 2.34+ и OpenSSH с поддержкой ssh-keygen -Y.")
            Link("Документация Git: настройки подписей", destination: URL(string: "https://git-scm.com/docs/git-config")!)
        }
    }
    private var sshGuide: some View {
        Group {
            step(1, "Выберите ключ", "Подключите флешку и оставьте USBKey запущенным. Можно использовать основной ключ ниже или создать отдельный Ed25519 в «Хранилище» → «Добавить» → «SSH-ключ». Открытый ключ отдельной записи копируется из её карточки в хранилище.")
            keyBlock
            step(2, "Разрешите ключ на сервере", "Войдите на сервер привычным способом под нужным пользователем. Выполните команды ниже на сервере. В редакторе добавьте скопированный открытый ключ отдельной строкой в конец authorized_keys, сохранив существующие строки. В nano: Control+O, Enter, затем Control+X.")
            CopyableCommand(title: "На сервере, под нужным пользователем", value: "mkdir -p ~/.ssh\nchmod 700 ~/.ssh\ntouch ~/.ssh/authorized_keys\nchmod 600 ~/.ssh/authorized_keys\nnano ~/.ssh/authorized_keys")
            step(3, "Подключитесь с Mac", "В команде замените user на имя пользователя сервера, а server.example.com — на его адрес. Путь к агенту уже подставлен для этого Mac. При первом подключении сверьте отпечаток сервера с администратором. Подтвердите запрос подписи в USBKey.")
            CopyableCommand(title: "В Терминале на Mac", value: "ssh -o IdentityAgent=\(shellSocket) -o ForwardAgent=no user@server.example.com")
            step(4, "Сохраните настройки подключения", "Для удобства добавьте блок ниже в ~/.ssh/config на Mac, перед общими правилами Host *. Замените HostName и User. После этого подключайтесь командой ssh my-server. Это фрагмент файла, его не нужно выполнять в терминале.")
            CopyableCommand(title: "Фрагмент ~/.ssh/config на Mac", value: "Host my-server\n    HostName server.example.com\n    User user\n    IdentityAgent \"\(socketPath)\"\n    ForwardAgent no")
            CopyableCommand(title: "Подключение по сохранённому имени", value: "ssh my-server")
            CopyableCommand(title: "Проверить открытые ключи агента на Mac", value: "SSH_AUTH_SOCK=\(shellSocket) ssh-add -L")
            note("Если ключ не виден, проверьте запущенный USBKey, флешку и разблокированный сеанс macOS. При Permission denied проверьте пользователя и authorized_keys на сервере. Если сервер отклоняет слишком много ключей, укажите IdentityFile с файлом нужного открытого ключа и IdentitiesOnly yes в Host-блоке.")
            note("Не нужно выполнять ssh-add с закрытым ключом. USBKey поддерживает Ed25519; импорт — OpenSSH без парольного шифрования. Агент не проверяет имя сервера; оставляйте ForwardAgent no. Извлечение флешки блокирует новые подписи, но не завершает уже открытые SSH-сеансы.")
            Link("Документация OpenSSH: IdentityAgent", destination: URL(string: "https://man.openbsd.org/ssh_config#IdentityAgent")!)
        }
    }
    private var vaultGuide: some View {
        Group {
            step(1, "Подготовьте носитель", "Подключите флешку с доступом на запись. В разделе «Устройство» выберите носитель и нажмите «Подготовить новый USB-ключ…». Ключ расшифровки остаётся в Связке ключей этого Mac.")
            step(2, "Добавьте записи", "В «Хранилище» нажмите «Добавить», укажите название и выберите пароль, токен или SSH-ключ. Можно хранить несколько записей. Для просмотра списка нажмите «Открыть» и подтвердите доступ.")
            step(3, "Назначьте значение для ввода", "Выберите пароль или токен в списке и нажмите «Назначить для «Ввести»». Выбор сохраняется на флешке. SSH-ключ используется агентом и не набирается в поле.")
            step(4, "Введите в другом приложении", "Поставьте курсор в нужное поле, откройте меню USBKey в строке состояния и нажмите «Ввести». Либо настройте глобальную комбинацию в разделе «Устройство». USBKey набирает значение без буфера обмена; Enter и Tab не отправляются.")
            note("При потере флешки или записи в Связке ключей восстановление секретов невозможно. Флешка не является аппаратно некопируемым токеном и не разблокирует FileVault или экран входа macOS.")
        }
    }
    private var deviceGuide: some View {
        Group {
            step(1, "Разрешите клавиатурный ввод", "Нажмите «Разрешить клавиатурный ввод…» в разделе «Устройство». В настройках macOS включите USBKey в «Конфиденциальность и безопасность» → «Универсальный доступ». После изменения разрешений вернитесь в USBKey и перезапустите приложение предложенной кнопкой.")
            step(2, "Настройте подтверждение", "Переключатель «Подтверждать каждый ввод через Touch ID / пароль» управляет набором паролей и токенов. Если он выключен, любой пользователь вашего разблокированного сеанса сможет ввести назначенное значение при подключённой флешке. Подписи Git и SSH всё равно требуют подтверждения.")
            step(3, "Запишите сочетание клавиш", "Включите «Глобальная комбинация», нажмите на поле сочетания и нажмите нужные клавиши с модификаторами. Выберите свободную комбинацию. Она вводит назначенную запись без открытия меню.")
            step(4, "Безопасно извлеките флешку", "В меню строки состояния нажмите «Извлечь». Дождитесь сообщения об успешном извлечении, затем отключите носитель. Завершите текущую подпись или ввод перед извлечением.")
            note("Если доступ включён, но ввод заблокирован, проверьте путь запущенной копии в разделе «Устройство». Удалите старую запись USBKey из разрешений macOS и добавьте /Applications/USBKey.app заново, затем перезапустите USBKey. Защищённые системные поля могут отклонять синтетические события.")
        }
    }
}
