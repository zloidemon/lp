# Введение

Для работы с данным лонгпулингом требуется

1. драйвер к тарантулу, поддерживающий асинхронный доступ (множество запросов
по одному коннекту). Например DR::Tarantool
1. асинхронный вебсервер. Например Twiggy или Coro::Twiggy
1. Tarantool 1.5
1. данный набор lua

# Использование

```lua

    lp = (require 'lp').new(0, 20 * 60)


    lp.push(key, value)
    lp.push_list(key1, value1, key2, value2, ...)

    ...

    local events = lp.subscribe(12345, 25, key1, key2, ...)

```

# Установка

Для установки необходимы файлы:

* `lua/lp.lua`
* `lua/on_lsn.lua`

Разместите их в `script_dir` рядом с Вашим `init.lua`.

## Инициализация

```lua
    lp = (require 'lp').new(0, 20 * 60)
```

Конструктор принимает два параметра:

1. Номер спейса на котором будет работать лонгпулинг
2. время жизни сообщения в секундах (после этого сообщение
будет удалено из БД процессом expiration)

Конфигурация спейса лонгпулинга должна быть такой:

```pre
{
    enabled = 1,
    index = [
        {
            type = "TREE",
            unique = 1,
            key_field = [
                {
                    fieldno = 0,
                    type = "NUM64"
                }
            ]
        },
        {
            type = "TREE",
            unique = 0,
            key_field = [
                {
                    fieldno = 2, # key
                    type = "STR",
                },
                {
                    fieldno = 0, # id
                    type = "NUM64"
                },
            ]
        },
    ]
}
```

Формат хранения сообщения в БД:

1. `ID` - идентификатор сообщения (присваивается `push`)
1. `time` - время когда создано сообщение (используется процессом
expiration)
1. `key` - ключ сообщения
1. `data` - данные связанные с сообщением (в обычном случае - сериализованный
(например JSON) объект).


## Добавление сообщения

Есть два метода, позволяющие добавить одно или несколько сообщений:

```lua

    lp.push(key, value)
    lp.push_list(key1, value1, key2, value2, ...)

```

Второй метод просто перевызывает первый в цикле.

## Подписка на сообщения

```lua

    local list = lp.subscribe(id, timeout, key1, key2, ...)

```

Подписывается на получение сообщений с ключами `key1`, `key2`, итп.
Подписка осуществляется на интервал времени `timeout`.

В качестве `id` необходимо передать стартовый `id` с которого
необходимо получать сообщения. `id=0` означает: "ожидать все сообщения,
начиная от текущего времени".

В списке возвращаются все полученные сообщения по переданным ключам
(если они есть), а так же завершающая запись, содержащая в себе
`id`, который можно использовать для следующего `subscribe`.

Таким образом алгоритм работы клиента выглядит следующим образом.


1. начало: `id=0`
2. запрос `lp.subscribe(id, timeout, key1, key2, ...)`
3. обработка списка полученных сообщений (все элементы списка кроме последнего)
4. id=id из последнего элемента списка
5. перейти к шагу 2

Для случая "лонгпулинг на сайте" пункты 1, 3, 4, 5 делаются на
клиенте при помощи JavaScript.
Пункт 2 делается на сервере при помощи асинхронного вебсервера (например Twiggy
или Node.JS).

