job "postgres-server" {
  datacenters = [
    "home"
  ]
  type = "service"

  constraint {
    attribute = "${node.class}"
    value     = "storage"
  }

  group "postgres" {
    count = 1

    restart {
      attempts = 10
      interval = "5m"
      delay    = "25s"
      mode     = "delay"
    }

    network {
      port "db" {
        to     = 5432
        static = 5432
      }
    }

    volume "pgdata" {
      type            = "host"
      source          = "postgres_data"
      read_only       = false
    }

    task "postgres" {
      driver = "docker"

      resources {
        cpu    = 500
        memory = 1024
      }

      env {
        POSTGRES_PASSWORD = "zasada"
        POSTGRES_DB       = "artifactory"
        PGDATA            = "/var/lib/postgresql/data"
        POSTGRES_PASSWORD = "zasada"
      }

      config {
        image = "postgres:16"

        ports = [
          "db"
        ]

        # если хочешь жёстко задать владельца файлов на диске
        # user = "999:999"
      }

      volume_mount {
        volume      = "pgdata"
        destination = "/var/lib/postgresql/data"
        read_only   = false
      }

      service {
        name = "postgres-server"
        port = "db"

        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
