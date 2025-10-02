job "artifactory" {
  datacenters = [
    "dc1"
  ]
  type = "service"

  update {
    max_parallel     = 1
    health_check     = "checks"
    min_healthy_time = "20s"
    healthy_deadline = "5m"
    auto_revert      = true
  }

  group "artifactory" {
    count = 1

    network {
      port "ui" {
        to = 8082
      }
      port "api" {
        to = 8081
      }
    }

    volume "data" {
      type            = "csi"
      source          = "nfs"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "multi-node-multi-writer"
    }

    task "artifactory" {
      driver = "docker"

      resources {
        memory = 2144
      }

      config {
        image = "jfrog/artifactory-oss:latest"

        ports = [
          "ui",
          "api"
        ]

        ulimit {
          nofile = "65536"
        }

        # user = "1030:1030"
      }

      volume_mount {
        volume      = "data"
        destination = "/var/opt/jfrog/artifactory"
        read_only   = false
      }

      env {
        EXTRA_JAVA_OPTIONS = "-Xms512m -Xmx2096m"
      }

      service {
        name = "artifactory"
        port = "ui"
        tags = [
          "http",
          "artifactory",
          "oss"
        ]

        check {
          name     = "ping"
          type     = "http"
          path     = "/artifactory/api/system/ping"
          interval = "15s"
          timeout  = "4s"
        }
      }

      restart {
        attempts = 5
        delay    = "10s"
        interval = "2m"
        mode     = "delay"
      }

      kill_timeout = "30s"
    }
  }
}
