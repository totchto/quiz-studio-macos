# Ключи Sparkle и лента обновлений

Рабочая памятка для выпуска обновлений «Квиз Студии». Относится к Sparkle 2.10.1.

## Один раз: ключ EdDSA

Инструменты Sparkle лежат в `.build/artifacts/sparkle/Sparkle/bin/` после `swift package resolve`.

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

- Закрытый ключ сохраняется в связке ключей macOS (`ed25519`), открытый ключ печатается в выводе.
- Запишите открытый ключ в `Resources/Info.plist` как `SUPublicEDKey`.
- Сделайте резервную копию закрытого ключа в согласованном защищённом хранилище:
  `generate_keys -x <файл>` (файл содержит base64 seed; после копирования удалите его с диска).
- Восстановление на другой машине: `generate_keys -f <файл>`.

Потеря закрытого ключа означает, что установленные версии больше не смогут принять обновления: ключ нельзя заменить без ручной переустановки приложения. Не коммитьте закрытый ключ, файлы `-x`, выгрузки Keychain и `.env` с ключом.

## Сборка релиза

```sh
QUIZSTUDIO_SIGN_IDENTITY="Developer ID Application: <имя> (<TEAMID>)" \
QUIZSTUDIO_NOTARY_PROFILE=<профиль notarytool> \
python3 build.py
```

- Без `QUIZSTUDIO_SIGN_IDENTITY` сборка подписывается ad hoc и пригодна только для локальной проверки: Sparkle отклонит обновление.
- Профиль `notarytool` создаётся заранее: `xcrun notarytool store-credentials <профиль> --apple-id … --team-id …`.
- `build.py` встраивает `Sparkle.framework`, добавляет rpath, подписывает вложенные компоненты снизу вверх (`XPCServices`, `Autoupdate`, `Updater.app`, framework, затем приложение), при необходимости отправляет ZIP в notarytool и staple.

## Лента

```sh
python3 scripts/make_appcast.py --version 0.21.0 \
  --previous https://github.com/totchto/quiz-studio-macos/releases/latest/download/appcast.xml
```

- По умолчанию закрытый ключ берётся из Keychain; в CI передайте `--key-file` (или `--ed-key-file -` внутри самого Sparkle при подаче ключа через stdin).
- Скрипт копирует заметки `Releases/v<версия>.md` рядом с архивом, генерирует `dist/sparkle/appcast.xml` и проверяет подпись архива.
- Загрузите в GitHub Release `v<версия>`: `dist/QuizStudio-macOS.zip` (прежняя публичная ссылка), `dist/sparkle/QuizStudio-<версия>.zip`, `dist/sparkle/appcast.xml`.
- `SUFeedURL` указывает на `https://github.com/totchto/quiz-studio-macos/releases/latest/download/appcast.xml`: этот адрес постоянен, а файл берётся из последнего опубликованного (не черновика и не prerelease) релиза.
- Старые записи ленты сохраняются, если передать `--previous`; без него в ленте останется только новая версия.

## Проверка

```sh
python3 Tests/check_updates.py
codesign --verify --deep --strict "dist/Квиз Студия.app"
xcrun stapler validate "dist/Квиз Студия.app"
```

`Tests/check_updates.py` проверяет HTTPS-ленту, 32-байтовый открытый ключ, политику автоматических проверок и закреплённую версию Sparkle. Он не проверяет подпись Developer ID и нотариальное заверение — для этого нужен сертификат и профиль notarytool.
