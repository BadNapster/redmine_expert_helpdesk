# Идея: разделитель ответа (reply separator) — обрезка цитат и добавление строки в ответ

**Статус:** идея / TODO. Не реализовано.
**Область:** `redmine_expert_helpdesk` — проектная настройка, входящая почта
(`MailProcessor`), ответ из трекера (`HelpdeskRepliesController`).

---

## Цель

Повторить поведение старого плагина `redmine_helpdesk`: отсекать цитируемое
содержимое входящих писем по настраиваемой строке-разделителю, чтобы в тикете
(и в описании нового тикета, и в notes журнала ответа) оставался только новый
текст клиента, а не процитированная переписка.

Функциональность имеет настройку строки (проектную). При пустой строке в
настройке функционал **отключён**. Разделитель также добавляется в начало
исходящего письма при отправке ответа клиенту **из трекера** — клиент отвечает
«выше линии», и эта же строка затем находится в его ответном письме.

## Как это делает старый плагин

Проектное поле `helpdesk-reply-separator`
(`redmine_helpdesk/db/migrate/010_create_custom_field_for_reply_separator.rb`,
по умолчанию `---- Please reply above this line ----`).

1. **Исходящий ответ** (`lib/redmine_helpdesk/helpdesk_mailer.rb`): строка
   добавляется в самое начало письма:

   ```ruby
   body = reply_separator + "\n\n" + body
   ```

2. **Входящая обработка** (`lib/redmine_helpdesk/patches/mailer_patch.rb`,
   `issue_edit`): из текста ответа вырезается всё от первого вхождения
   разделителя до конца (удаляется процитированная переписка):

   ```ruby
   journal.notes = journal.notes.gsub(/#{reply_separator}.*/m, '')
   ```

## Решения (согласованы)

- Настройка — **проектная** (`HelpdeskProjectSetting.reply_separator`), рядом с
  остальными настройками ответа. Пустая строка = выключено.
- Разделитель добавляется в исходящем направлении **только в ответ из трекера**
  (`HelpdeskRepliesController`). Автоответчик и init-письма НЕ трогаем.
- Входящая обрезка применяется и к новому тикету (description), и к ответу
  (journal notes) — если разделителя в тексте нет, текст не меняется.

## Где реализовать в новом плагине

### 1. Настройка

- Миграция `db/migrate/066_add_reply_separator_to_helpdesk_project_settings.rb`:
  колонка `reply_separator` (string) в `helpdesk_project_settings` (паттерн
  `065_add_kb_extract_settings.rb`, с `column_exists?`).
- Форма `app/views/projects/settings/_helpdesk.html.erb` (fieldset "Reply
  settings"): текстовое поле `helpdesk_project_setting[reply_separator]` с
  подсказкой.
- Контроллер `app/controllers/helpdesk_project_settings_controller.rb`
  (`update_reply_settings`): `setting.reply_separator = params[...].to_s.strip`.
- API: `app/controllers/helpdesk_project_settings_api_controller.rb` (update) и
  `lib/redmine_expert_helpdesk/api_serializers.rb` (`project_setting` →
  `api.reply_separator`).
- Локали `config/locales/{en,de,ru}.yml`:
  `label_helpdesk_reply_separator`, `text_helpdesk_reply_separator_hint`.

### 2. Новый модуль `lib/redmine_expert_helpdesk/reply_separator.rb`

В стиле `InlineImages` / `AttachmentBlacklist` (`module_function`):

```ruby
module RedmineExpertHelpdesk
  module ReplySeparator
    module_function

    # Настроенная строка разделителя проекта, или nil (пустая = выключено).
    def separator_for(project)
      HelpdeskProjectSetting.for_project(project).reply_separator.to_s.strip.presence
    end

    # Обрезает всё от первого вхождения разделителя до конца. Сравнение
    # подстрокой (не regex): безопасно для спецсимволов в разделителе и находит
    # его даже под префиксом цитаты "> ".
    def strip(text, separator)
      return text if separator.blank? || text.blank?

      idx = text.index(separator)
      idx ? text[0...idx].rstrip : text
    end

    # Применяет обрезку к сохранённому тексту объекта (description нового
    # тикета или notes журнала ответа) через InlineImages.stored_text/store_text
    # (пишут через update_all, без создания журнала/уведомления).
    def strip_stored!(object, issue)
      separator = separator_for(issue.project)
      text      = RedmineExpertHelpdesk::InlineImages.stored_text(object)
      stripped  = strip(text, separator)
      return false if stripped == text

      RedmineExpertHelpdesk::InlineImages.store_text(object, stripped)
    end

    # HTML для ответа из трекера: "<p>#{h(separator)}</p>\n\n" + body_html.
    def prepend_html(body_html, separator)
      "<p>#{ERB::Util.html_escape(separator)}</p>\n\n" + body_html
    end
  end
end
```

### 3. Входящая почта (`lib/redmine_expert_helpdesk/mail_processor.rb`)

В `process_message`, внутри `if issue`, **до** `InlineImages.rewrite!` (чтобы
cid-маркеры процитированных картинок не резолвились):

```ruby
RedmineExpertHelpdesk::ReplySeparator.strip_stored!(object, issue)
InlineImages.rewrite!(object, mime)
```

### 4. Исходящий ответ из трекера
(`app/controllers/helpdesk_replies_controller.rb`)

В `create`, после сборки `body_html` и **до** ветвления SMTP/MIME (одна точка
правки покрывает оба транспорта):

```ruby
separator = RedmineExpertHelpdesk::ReplySeparator.separator_for(@project)
body_html = RedmineExpertHelpdesk::ReplySeparator.prepend_html(body_html, separator) if separator
```

### Тесты

- unit `test/unit/reply_separator_test.rb`:
  - `strip`: обрезает от разделителя до конца; без разделителя не меняет текст;
    nil/пустой разделитель = no-op;
  - `strip_stored!` на реальных фикстурах: `Issue` (description) и `Journal`
    (notes) обрезаются.
- integration `test/integration/helpdesk_reply_separator_test.rb` (паттерн
  `helpdesk_reply_attachments_test.rb`):
  - ответ из трекера с настроенным разделителем → письмо начинается с `<p>…</p>`
    (и SMTP, и MIME-путь);
  - пустая настройка → письмо без разделителя.

## Замечания / риски

- Обрезка идёт от **первого** вхождения разделителя (как в старом плагине): если
  клиент сам вставил такую строку в текст письма, всё после неё будет отрезано.
  Низкая вероятность, поведение осознанно повторяет старый плагин.
- Разделитель добавляется только в ответы из трекера, поэтому на первое письмо
  (автоответчик/init) клиент получит его не сразу — обрезка заработает после
  первого ответа агента из трекера.
- `store_text` пишет через `update_all` и не создаёт журнал — обрезка не породит
  запись «отредактировано» и уведомление.
