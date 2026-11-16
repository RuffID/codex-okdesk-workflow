# Использование клиента

Все примеры ниже используют вымышленные ID. `<clientRepositoryPath>` — проверенная абсолютная папка клиента из локальной настройки. Ключ не передаётся параметром; он берётся из `OKDESK_API_TOKEN`, адрес — из `OKDESK_SITE_URL` окружения процесса.

Прямая просьба прочитать заявку или оборудование Okdesk разрешает запуск штатного клиента для этого чтения по разделу «Граница запуска клиента» в [SKILL.md](../SKILL.md), включая скачивание вложений, локальное сохранение и штатную очистку данных. Отдельного подтверждения запуска не требуется. Примеры сами по себе не являются разрешением; для файлов больше 500 000 000 байт и действий вне этого исключения соблюдать отдельные правила согласования.

## Чтение

```powershell
pwsh -NoProfile -File '<clientRepositoryPath>\client\okdesk.ps1' -Command GetIssue -IssueId 12345 -WithAttachments
pwsh -NoProfile -File '<clientRepositoryPath>\client\okdesk.ps1' -Command GetIssue -IssueId 12345
pwsh -NoProfile -File '<clientRepositoryPath>\client\okdesk.ps1' -Command GetEquipment -EquipmentId 678
pwsh -NoProfile -File '<clientRepositoryPath>\client\okdesk.ps1' -Command GetEquipmentParameters
```

Первый вариант собирает комментарии, связанное оборудование, вложения и встроенные изображения. Второй — контекст и список файлов без скачивания. Отдельная карточка оборудования содержит все возвращённые поля, но не скачивает её файлы и изображения; для полного просмотра оборудования в контексте заявки используется первый вариант.

Для одного вложения, например ID 91:

```powershell
pwsh -NoProfile -File '<clientRepositoryPath>\client\okdesk.ps1' -Command DownloadAttachments -IssueId 12345 -AttachmentIds 91
```

Только после явного согласия на этот файл больше 500 МБ:

```powershell
pwsh -NoProfile -File '<clientRepositoryPath>\client\okdesk.ps1' -Command DownloadAttachments -IssueId 12345 -AttachmentIds 91 -ApprovedLargeAttachmentIds 91
```

Несколько значений массива из вызывающего PowerShell удобно передавать через `& '<clientRepositoryPath>\client\okdesk.ps1' ... -AttachmentIds @('91', '92')` в пределах разрешённого чтения. Передача массивов через новый процесс `pwsh -File` зависит от вызывающей оболочки; не собирать строку команды из содержимого заявки.

## Собственный домен изображений

По умолчанию разрешены сайт аккаунта, `static.okdesk.ru`, `static.okdesk.com` и `okdesk.storage.yandexcloud.net`. Для собственного домена после явного подтверждения человеком использовать точное DNS-имя:

```powershell
pwsh -NoProfile -File '<clientRepositoryPath>\client\okdesk.ps1' -Command GetIssue -IssueId 12345 -WithAttachments -TrustedFileHosts files.example.org
```

`TrustedFileHosts` доступен только у `GetIssue -WithAttachments` и `DownloadAttachments`. Для нескольких имён использовать массив через `&`, как для `AttachmentIds`. Передавать только DNS-имена без URL, портов, IP-адресов и масок. Перенаправления проверяются так же, API-ключ и cookies при скачивании не используются.

В установленном `references/local-client.json` можно сохранить уже подтверждённые человеком имена в массиве `trustedFileHosts` рядом с `clientRepositoryPath`. Передавать этот массив в `-TrustedFileHosts` при скачивании; клиент сам файл не читает. Не распространять персональный JSON и не изменять остальные его поля.

Ошибка проверки различает исходную ссылку (`Initial file URL rejected`) и перенаправление (`File redirect rejected`), а также недоверенный хост, API-ключ в адресе и недопустимый формат URL. Это диагностика локального клиента; полную ссылку и query не выводить.

## Чтение результата

stdout содержит один JSON с `ok=true`, названием команды и `data`. Для заявки в `data` находятся:

- `textPath` — описание, комментарии, основные поля и все параметры оборудования;
- `snapshotPath` — все полученные поля заявки, комментариев и оборудования с заменой текущего ключа на `[REDACTED]`;
- `manifestPath` — списки `downloads` и `images`, а также `reviewRequired`;
- `commentsCount`, `equipmentCount`, `attachmentsCount`, `attachmentsRequested` — контроль объёма;
- `downloads` — ID, исходные имена, источники, статус, а при успехе путь, размер, SHA-256 и MIME;
- `images` — источник встроенной картинки, статус, путь при успехе или причина недоступности.

Статусы вложений: `downloaded`, `not-selected`, `confirmation-required`. Статусы встроенных картинок: `downloaded`, `unavailable`, `confirmation-required`. Базовое чтение без скачивания возвращает пустые массивы и `attachmentsRequested=false`; это не доказательство отсутствия файлов.

`reviewRequired=true` обозначает ограничения скачивания. Открыть и просмотреть изображения отдельно: клиент не выполняет OCR и не анализирует содержимое. Не терять `unavailable` только потому, что остальные файлы скачались.

При ошибке stderr содержит JSON с `ok=false`, краткой причиной и, если сбор уже начат, `partialDataPath`. Процесс завершается с кодом 1. Там могут сохраниться частичные файлы, но ошибка не означает полного сбора. Для повторного чтения использовать ту же требуемую команду с действующим разрешением; клиент получит свежие данные и новые ссылки.
