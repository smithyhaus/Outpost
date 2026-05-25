# Manticore Search — local config

Standalone is the default. This directory exists so the **replication hook**
is in place: the compose service mounts `./conf.d` into the container at
`/etc/manticoresearch/conf.d/`, but the shipped Manticore default config
does not `include` that directory — so the contents are inert until you
opt in.

## Layout

```
manticore/
├── README.md                                 (this file)
└── conf.d/
    ├── .gitkeep
    └── 99-replication.conf.disabled          (sample, NOT loaded)
```

## When you do not need replication

Do nothing. The default Manticore image runs standalone with RT indexes
out of the box on:

| Port | Protocol            | Use                                        |
| ---- | ------------------- | ------------------------------------------ |
| 9308 | HTTP / JSON         | `curl http://localhost:9308/sql ...`        |
| 9306 | MySQL wire protocol | `mysql -h127.0.0.1 -P9306`                  |
| 9312 | binary / Sphinx API | reserved; also used by replication later    |

## When you want to turn on replication

1. **Rename the sample**

   ```sh
   mv conf.d/99-replication.conf.disabled conf.d/99-replication.conf
   ```

2. **Drop in a `manticore.conf` that includes `conf.d/`**

   Create `core/compose/manticore/manticore.conf`:

   ```conf
   searchd {
       listen = 0.0.0.0:9306:mysql
       listen = 0.0.0.0:9308:http
       listen = 0.0.0.0:9312
       log = /var/log/manticore/searchd.log
       query_log = /var/log/manticore/query.log
       pid_file = /var/run/manticore/searchd.pid
       data_dir = /var/lib/manticore

       include = /etc/manticoresearch/conf.d/*.conf
   }
   ```

   Then mount it via `core/compose/docker-compose.yml` under the `manticore`
   service `volumes:`:

   ```yaml
   - ./manticore/manticore.conf:/etc/manticoresearch/manticore.conf:ro
   ```

3. **Publish the replication port range** in `docker-compose.yml`:

   ```yaml
   - "0.0.0.0:9315-9325:9315-9325"
   ```

4. **Restart the service** and create the cluster:

   ```sh
   docker compose -f core/compose/docker-compose.yml up -d manticore
   docker compose -f core/compose/docker-compose.yml exec manticore \
       mysql -h127.0.0.1 -P9306 -e 'CREATE CLUSTER posts'
   ```

   Reference: <https://manual.manticoresearch.com/Creating_a_cluster>.

## Why a `.disabled` suffix

If the file ended in `.conf`, any future `include = conf.d/*.conf`
directive would pick it up immediately and break a standalone node
that has no peers. The suffix makes the activation an explicit
two-step decision (rename, then re-`up`).

## Why the mount is not `:ro`

Manticore's container entrypoint `chown`s `/etc/manticoresearch/conf.d`
to its runtime user at start. A `:ro` bind mount causes that chown to
fail with `Read-only file system` and the container restarts in a loop.
The mount is writable but Outpost itself never writes into it from
inside the container — host files stay unmodified.
