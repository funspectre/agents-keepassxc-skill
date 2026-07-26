# agents-keepassxc-skill

*[English](README.md) · Русский*

[Agent Skill](https://agents.md) для работы с секретами из локальной базы
**KeePassXC** — так, чтобы значения не попадали ни в контекст модели, ни в
историю шелла, ни в вывод `ps`.

Скилл написан в портируемом формате `SKILL.md`, поэтому один и тот же каталог
работает в Claude Code, Codex CLI, Cursor, Gemini CLI и любом другом харнессе,
который умеет скиллы; для тех, кто читает только `AGENTS.md`, установщик пишет
блок-указатель. См. [Установка](#установка).

Это KeePassXC-аналог существующих скиллов для 1Password: та же идея ссылок в духе
`op://` и инъекции в духе `op run`, но за ней локальный `.kdbx` и системный
кошелёк вместо облачного хранилища.

## Идея

Агент должен уметь *воспользоваться* секретом, ни разу его не *увидев*.

```bash
kpsec run -e GITLAB_TOKEN=kp://gitlab/api -- glab api /user   # значение только в env потомка
kpsec check kp://gitlab/api                                   # OK  len=26 sha256:1f3a9c02
```

Всё, что дочерний процесс напечатает и что совпадёт с секретом, заменяется на
`«redacted»` до того, как попадёт в терминал.

## Почему недостаточно `keepassxc-cli show`

Три причины, и из них вырастает вся конструкция:

1. **`keepassxc-cli` печатает в stdout.** В агентской сессии stdout — это и есть
   контекст модели. Один `show -a Password`, и секрет уже в транскрипте.
2. **`keepassxc-cli` не умеет работать с разблокированной GUI-базой.** Каждый
   вызов снова просит мастер-пароль, а у шелла агента нет tty, чтобы его ввести.
3. **Пароль, переданный флагом, виден всем** через `/proc/<pid>/cmdline` на время
   работы команды.

Отсюда: мастер-пароль лежит в системном кошельке, кэшируется в kernel keyring с
TTL; значения резолвятся внутри процесса и уходят в окружение потомка; вывод
потомка фильтруется на обратном пути.

## Установка

```bash
git clone https://github.com/jidckii/agents-keepassxc-skill.git
cd agents-keepassxc-skill
./install.sh --bin    # во все обнаруженные харнессы + kpsec в PATH
kpsec init            # создаёт ~/.pass/agents.kdbx и кладёт мастер-ключ в кошелёк
```

На Windows — `.\install.ps1` (те же флаги в стиле PowerShell: `-Project`,
`-AllUser`, `-Copy`, `-List`).

`install.sh` ставит симлинк на каталог скилла, поэтому `git pull` обновляет его
сразу во всех харнессах (`--copy`, если нужны независимые копии). Установка
идемпотентна — запускай повторно после появления нового харнесса.

| Куда | Харнессы | Как |
|---|---|---|
| `~/.claude/skills/` | Claude Code | `./install.sh` (автодетект) |
| `~/.codex/skills/` | Codex CLI | `./install.sh` (автодетект) |
| `~/.gemini/skills/` | Gemini CLI, Antigravity | `./install.sh` (автодетект) |
| `<проект>/.cursor/skills/` | Cursor — у него нет персонального каталога скиллов | `./install.sh --project` |
| `<проект>/.agents/skills/` | Cline, Amp, opencode, Antigravity | `./install.sh --project` |
| `<проект>/AGENTS.md` | Copilot, Windsurf, Aider, Zed, Devin, Jules, … | `./install.sh --project` |
| куда угодно ещё | любой харнесс с каталогом скиллов | `./install.sh --skills-dir PATH` |

`./install.sh --list` покажет пути и что обнаружено. `--all-user` поставит во все
известные харнессы, даже если они ещё не установлены.

Для харнессов, знающих только AGENTS.md, установщик дописывает короткий
блок-указатель между маркерами `<!-- keepassxc-secrets:begin -->` — повторный
запуск заменяет только этот блок, остальной файл не трогает.

Пакеты для дистрибутивов и особенности кошельков — в
[`references/setup.md`](skills/keepassxc-secrets/references/setup.md).

## Ссылки на секреты

```
kp://<группа>/<запись>[#<Атрибут>]
```

Атрибут по умолчанию — `Password`. `UserName`, `Title`, `URL` и `Notes` считаются
публичными и из вывода не вырезаются.

```
kp://gitlab/api            # пароль
kp://gitlab/api#UserName   # alice
```

В `.env.tpl` лежат ссылки, а не значения, — такой файл можно коммитить:

```
REGISTRY_USER=deployer
REGISTRY_PASSWORD=kp://registry/deployer
```

```bash
kpsec run --env-file=.env.tpl -- docker compose up
```

## Команды

| Команда | Что делает |
|---|---|
| `kpsec init` | создать базу, сгенерировать и сохранить мастер-ключ |
| `kpsec status` | откуда берётся мастер-пароль и открывается ли база |
| `kpsec ls [группа]` | список записей (значений — никогда) |
| `kpsec check <ссылка>…` | проверить, что ссылка резолвится: длина и префикс sha256 |
| `kpsec run [--env-file=F] [-e VAR=ссылка] -- cmd` | запустить команду с секретами в окружении |
| `kpsec add <путь> [-u user] [--url u] [-g]` | добавить или обновить запись; значение вводится в GUI-диалоге |
| `kpsec clip <ссылка>` | скопировать значение в буфер обмена на 15 секунд |
| `kpsec lock` | сбросить кэш мастер-пароля |
| `kpsec relocate <путь>` | перепривязать мастер-ключ после переезда файла `.kdbx` |
| `kpsec show-master` | показать мастер-пароль в GUI-диалоге (только для человека) |

## Свои инструменты поверх

`kpsec_core.py` импортируется как модуль. Резолви секрет внутри процесса и
фильтруй вывод потомка — тогда значение не проходит через промежуточный stdout:

```python
import os, subprocess, sys
sys.path.insert(0, os.path.expanduser("~/.claude/skills/keepassxc-secrets/scripts"))  # или куда установлено
import kpsec_core as kpsec

cfg = kpsec.load_config()
token = kpsec.resolve(cfg, "kp://gitlab/api")
proc = subprocess.Popen(["glab", "api", "/user"],
                        env={**os.environ, "GITLAB_TOKEN": token},
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
kpsec.stream_redacted(proc, [token])
sys.exit(proc.wait())
```

Полезные точки входа: `load_config()`, `resolve(cfg, ref, soft=False)`,
`build_env(cfg, pairs)`, `stream_redacted(proc, secrets)` и хелперы кошелька
`keyctl_read/keyctl_write/keyctl_unlink` — для кэширования производных
credentials вроде сессионных токенов.

## Безопасность

Полная модель угроз — включая то, от чего эта конструкция намеренно **не**
защищает, — в
[`references/security.md`](skills/keepassxc-secrets/references/security.md).
Коротко:

- Секреты агентов живут в отдельной `agents.kdbx`, а не в твоей личной базе.
- Мастер-пароль никогда не пишется на диск; кэш — память ядра с TTL.
- Редакция вывода держит значения вне транскриптов, но не мешает агенту, которому
  разрешено выполнять произвольные команды, вынести секрет наружу. Это
  ограничивается правилами доступа твоего харнесса — готовые лежат в том же файле.

## Платформы

`keepassxc-cli` ≥ 2.7 и `python3` нужны везде. Различается то, где лежит
мастер-ключ и как у тебя его спрашивают:

| | Хранилище ключа | Промпт | Дополнительно |
|---|---|---|---|
| Linux, KDE/GNOME | Secret Service, разблокируется при логине через PAM | kdialog / zenity | `keyutils` для кэша с TTL |
| Linux, Hyprland/Sway/i3 | собственный Secret Service KeePassXC или отдельный gnome-keyring | pinentry (Qt/GTK/curses) | см. [`platforms.md`](skills/keepassxc-secrets/references/platforms.md) |
| macOS | login Keychain через `security` | диалог osascript | CLI лежит внутри app bundle |
| Windows | Credential Manager через `keyring` | диалог `Get-Credential` | ставить через `install.ps1` |

`kpsec status` печатает, какой бэкенд используется на самом деле; `KPSEC_KEYRING`
закрепляет конкретный. В минималистичной Linux-сессии слот
`org.freedesktop.secrets` обычно свободен — это единственный случай, когда проще
всего включить собственную Secret Service интеграцию KeePassXC. Подробности и
PAM-сниппеты — в
[`references/platforms.md`](skills/keepassxc-secrets/references/platforms.md).

## Благодарности

Подход «ссылка вместо значения плюс инъекция» пришёл со стороны 1Password, в
первую очередь из
[kcmadden/claude-code-1password-skill](https://github.com/kcmadden/claude-code-1password-skill):
ссылки `op://`, `op run` для инъекции и правило коммитить шаблоны, а не значения.
Здесь эти идеи сохранены, но облачное хранилище заменено локальным `.kdbx` плюс
системный кошелёк — из-за чего задача разблокировки (и большая часть здешней
конструкции) выглядит иначе.

## Лицензия

MIT
