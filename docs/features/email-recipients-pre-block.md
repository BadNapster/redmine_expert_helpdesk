# Идея: префикс `<pre></pre>` с адресатами при создании тикета из почты

**Статус:** идея / TODO. Не реализовано.
**Область:** `redmine_expert_helpdesk`, обработка входящей почты (`MailProcessor`).

---

## Цель

При создании тикета из входящей почты добавлять в начало описания тикета
заголовки письма (From / To / Cc / Date), обёрнутые в `<pre></pre>`, — так,
как это делал старый плагин `redmine_helpdesk`. По желанию — также в notes
журнала при входящем ответе.

## Как это делал старый плагин

`plugins/redmine_helpdesk/lib/redmine_helpdesk/patches/mail_handler_patch.rb`
(метод `email_details`):

```ruby
def email_details
  details =  "From: " + @email[:from].formatted.first + "\n"
  details << "To:   " + @email[:to].formatted.join(', ') + "\n" if !@email.to.nil?
  details << "Cc:   " + @email[:cc].formatted.join(', ') + "\n" if !@email.cc.nil?
  details << "Date: " + @email[:date].to_s + "\n"
  "<pre>\n" + Mail::Encodings.unquote_and_convert_to(details, 'utf-8') + "</pre>\n\n"
end
```

Подстановка:
- новый тикет: `issue.description = email_details + issue.description`
- ответ: `last_journal.notes = email_details + last_journal.notes`

## Где реализовать в новом плагине

Файл: `lib/redmine_expert_helpdesk/mail_processor.rb`, метод `process_message`.
Там после `MailHandler.receive` уже есть разбор письма
(`parsed_mail = Mail.read_from_string(mime)`) и сохранение получателей в
`HelpdeskMessage` (`recipient_to` / `recipient_cc`).

### Эскиз реализации

Два приватных метода в `MailProcessor`:

```ruby
# "<pre>\nFrom: ...\nTo:   ...\nCc:   ...\nDate: ...\n</pre>\n\n"
def email_header_block(mail)
  return '' unless mail

  details = "From: " + mail[:from]&.formatted&.first.to_s + "\n"
  details << "To:   " + mail[:to].formatted.join(', ') + "\n" if mail.to.present?
  details << "Cc:   " + mail[:cc].formatted.join(', ') + "\n" if mail.cc.present?
  details << "Date: " + mail[:date]&.to_s.to_s + "\n"
  "<pre>\n" + Mail::Encodings.unquote_and_convert_to(details, 'utf-8') + "</pre>\n\n"
end

def prepend_email_header(issue, mail, object)
  block = email_header_block(mail)
  return false if block.blank?

  text = RedmineExpertHelpdesk::InlineImages.stored_text(object).to_s
  RedmineExpertHelpdesk::InlineImages.store_text(object, block + text)
rescue StandardError => e
  Rails.logger.warn "Helpdesk: mail header block failed: #{e.message}"
  false
end
```

Вызов в `process_message`, перед `msg = HelpdeskMessage.create!(...)`,
переиспользуя уже разобранный `parsed_mail`:

```ruby
parsed_mail = Mail.read_from_string(mime) rescue nil
prepend_email_header(issue, parsed_mail, object)
```

### Ключевые моменты

- `object` — это `Issue` (новый тикет) или `Journal` (входящий ответ).
  `InlineImages.stored_text` / `store_text` уже умеют читать/писать текст и для
  issue (`description`), и для journal (`notes`), причём `store_text` пишет через
  `update_all` в обход проблем с `lock_version` (это происходит после
  `MailHandler.receive`, экземпляр может быть на версию «старше»).
- Порядок в `process_message`: вставка должна быть **после**
  `InlineImages.rewrite!` (он правит описание/notes) и **после**
  `apply_new_issue_defaults` (он делает `issue.reload` и затёр бы префикс).
- Принятые решения (по согласованию с заказчиком):
  - добавлять и в описание нового тикета, и в notes журнала ответа;
  - без настройки включения/выключения (всегда включено, как в старом плагине).

### Тесты

Новый `test/unit/mail_processor_email_header_test.rb` (стиль
`mail_processor_filter_test.rb`, но с реальными фикстурами `issues`/`journals`,
чтобы `store_text` реально записывал):
- формат блока (`<pre>\nFrom: …\nTo:   …\nCc:   …\nDate: …\n</pre>`);
- префикс добавляется в начало описания реального `Issue`, оригинальный текст
  сохраняется в конце;
- префикс добавляется к notes журнала для ответа (`Journal`);
- устойчивость: `nil`/неразбираемая почта → без ошибок, без изменений текста.

## Замечания / риски

- Блок попадает в текст, который читают AI-функции (суммаризация, проверка
  полноты, извлечение в базу знаний) — адреса получателей окажутся в их
  контексте. Не блокер, но стоит учесть (в KB-извлечении уже есть инструкция
  не включать персональные данные).
- Для ответов блок пишется в notes журнала — в истории тикета перед текстом
  ответа появится `<pre>`-вставка с заголовками письма (как было в старом
  плагине).
- Формат вывода заголовков проверен на текущей версии Mail-гема
  (например, `From: Klaus Kunde <kunde@example.de>`, дата в формате исходного
  заголовка письма).
