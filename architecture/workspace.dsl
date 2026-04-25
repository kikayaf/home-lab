/*
 * =============================================================================
 * Home Lab architecture - Structurizr DSL (C4 model, layered)
 * =============================================================================
 *
 * Organised as a well-architected layered system:
 *
 *   Edge & Access layer     (user-facing entry points, DNS, reverse proxy)
 *   Application layer       (workloads, business logic, tooling)
 *   Platform layer          (k3s, container runtime)
 *   Data layer              (databases, object store, backups)
 *   Security layer          (cross-cutting: firewall, NAT rules)
 *   Observability layer     (cross-cutting: metrics, logs, traces)
 *   Infrastructure layer    (deployment view: hardware, Hyper-V, VMs, Docker)
 *
 * Modeling conventions:
 *   - Each SERVICE is a C4 container. Most deploy as Docker containers;
 *     a few are native systemd units (tailscale, k3s); two are kernel
 *     features (iptables, ufw).
 *   - Groups in the container view map one-to-one to architectural layers.
 *   - Layer-<name> tags drive per-layer background color.
 *   - Docker / Native / Kernel tags drive element shape.
 *   - Tech field on every relationship (protocol/port/mechanism).
 *
 * Rendering:
 *   - Static site  : ghcr.io/avisi-cloud/structurizr-site-generatr generate-site
 *   - Zero-install : https://structurizr.com/dsl or https://playground.structurizr.com
 *   - VS Code      : "Structurizr DSL" extension (ciarant)
 * =============================================================================
 */

workspace "Home Lab" "Layered Ubuntu/Hyper-V lab on a Windows host. Edge, application, platform, data, security, and observability layers, mostly deployed as Docker containers." {

    !identifiers hierarchical

    model {

        operator = person "Operator" "Admin and primary user of the lab"

        internet = softwareSystem "Internet" "Public internet" {
            tags "External"
        }
        homeNet = softwareSystem "Home network" "ISP router, 192.168.1.0/24, gateway .254" {
            tags "External"
        }
        tailnet = softwareSystem "Tailscale tailnet" "Mesh VPN for remote admin and subnet routing" {
            tags "External"
        }

        homeLab = softwareSystem "Home Lab" "Seven-VM Ubuntu cluster on Hyper-V. Lab subnet 192.168.100.0/24, isolated behind NAT." {

            group "Edge and Access layer" {
                tailscale = container "Tailscale" "Subnet router (192.168.100.0/24 into tailnet) + Tailscale SSH + Funnel for work-PC access" "Go · systemd" {
                    tags "EdgeNative"
                }
                coredns = container "CoreDNS" "Authoritative for *.lab.local, forwards the rest upstream, served via Tailscale Split DNS" "Docker: coredns/coredns:1.11.3" {
                    tags "EdgeDocker"
                }
                nginx = container "nginx" "Reverse proxy. Dispatches *.lab.local by Host header. Serves TLS with lab CA wildcard cert." "Docker: nginx:1.27-alpine" {
                    tags "EdgeDocker"
                }
            }

            group "Application layer" {
                workflows = container "Workflow runner" "Scheduled jobs, CI agents, operational automation (planned)" "Docker (TBD)" {
                    tags "AppPlanned"
                }
                devtools = container "Platform tools" "IaC runners, templating, internal CLI sandbox (planned)" "Docker (TBD)" {
                    tags "AppPlanned"
                }
                modelServer = container "Model serving" "AI/ML model inference endpoint (planned)" "Docker (TBD)" {
                    tags "AppPlanned"
                }
                structurizr = container "Structurizr site" "Static site rendered from this workspace.dsl; makes the architecture diagrams available at arch.lab.local" "Docker: ghcr.io/avisi-cloud/structurizr-site-generatr" {
                    tags "AppDocker"
                }
                codeServer = container "code-server" "Browser VS Code. Internal at code.lab.local; public via Tailscale Funnel for work-PC use." "Docker: codercom/code-server:4.95.3" {
                    tags "AppDocker"
                }
                vaultwarden = container "Vaultwarden" "Self-hosted Bitwarden-compatible password manager. HTTPS at vault.lab.local. Postgres-backed." "Docker: vaultwarden/server:1.35.7" {
                    tags "AppDocker"
                }
            }

            group "Platform layer" {
                k3sServer = container "k3s server" "Kubernetes API, scheduler, controller-manager, embedded SQLite. Traefik disabled (nginx owns ingress)." "k3s v1.34.6 · systemd" {
                    tags "PlatformNative"
                }
                k3sAgent01 = container "k3s agent (node01)" "kubelet + containerd, hosts workload pods" "k3s v1.34.6 · systemd" {
                    tags "PlatformNative"
                }
                k3sAgent02 = container "k3s agent (node02)" "kubelet + containerd, hosts workload pods" "k3s v1.34.6 · systemd" {
                    tags "PlatformNative"
                }
            }

            group "Data layer" {
                postgres = container "PostgreSQL" "Primary OLTP store, one logical database per app. pgvector 0.8.0 extension available." "Docker: pgvector/pgvector:0.8.0-pg16" {
                    tags "DataDocker"
                }
                minio = container "MinIO" "S3-compatible object storage. API at s3.lab.local, console at minio.lab.local." "Docker: minio/minio" {
                    tags "DataDocker"
                }
                redis = container "Redis" "In-memory cache + simple queue. AOF + LRU eviction at 256 MB." "Docker: redis:7-alpine" {
                    tags "DataDocker"
                }
                restic = container "restic" "Encrypted backups of Postgres + critical volumes to MinIO and offsite (planned)" "Docker: restic/restic" {
                    tags "DataPlanned"
                }
            }

            group "Security layer (cross-cutting)" {
                iptables = container "iptables NAT" "Masquerades lab egress from 192.168.100.0/24 through eth1 on the home network" "Kernel netfilter" {
                    tags "SecurityKernel"
                }
                ufw = container "ufw" "Per-host firewall policy on every VM. Default deny inbound, trust lab subnet and tailnet." "Kernel netfilter" {
                    tags "SecurityKernel"
                }
            }

            group "Observability layer (cross-cutting)" {
                prometheus = container "Prometheus" "Scrapes metrics from every layer (details omitted); long-term storage in MinIO (planned)" "Docker: prom/prometheus" {
                    tags "ObsPlanned"
                }
                grafana = container "Grafana" "Dashboards over Prometheus and Loki (planned)" "Docker: grafana/grafana" {
                    tags "ObsPlanned"
                }
                loki = container "Loki" "Log aggregation; chunks in MinIO (planned)" "Docker: grafana/loki" {
                    tags "ObsPlanned"
                }
            }
        }

        // --- Relationships ----------------------------------------------------
        // Every relationship has a tech field (protocol or port), no unlabelled edges.
        // Observability "scrapes everything" is captured in prometheus's description
        // rather than drawn per target, to keep the container view readable.

        // Operator paths
        operator -> tailnet "Connects remotely via" "Tailscale client"
        operator -> homeLab.tailscale "Remote admin over SSH" "SSH via Tailscale"
        operator -> homeLab.structurizr "Views lab architecture" "HTTPS browser"
        operator -> homeLab.codeServer "Edits, ssh/kubectl into lab via browser" "HTTPS browser"
        operator -> homeLab.vaultwarden "Stores/retrieves lab credentials" "HTTPS + Bitwarden clients"

        // External routing
        tailnet -> homeLab.tailscale "Exposes lab subnet and routes remote traffic" "Tailscale protocol"
        homeLab.iptables -> homeNet "NAT egress via eth1" "IPv4 TCP/UDP"
        homeNet -> internet "WAN" "IPv4"

        // Edge tying layers together
        homeLab.tailscale -> homeLab.iptables "Tailnet traffic lands on the lab subnet" "IP forwarding"
        homeLab.nginx -> homeLab.k3sServer "Proxies *.lab.local to k3s Services (NodePort)" "HTTPS"
        homeLab.nginx -> homeLab.structurizr "Proxies arch.lab.local to static site" "HTTPS"
        homeLab.nginx -> homeLab.codeServer "Proxies code.lab.local" "HTTPS"
        homeLab.nginx -> homeLab.vaultwarden "Proxies vault.lab.local" "HTTPS"
        homeLab.nginx -> homeLab.minio "Proxies s3.lab.local, minio.lab.local" "HTTPS"
        homeLab.nginx -> homeLab.grafana "Proxies grafana.lab.local (planned)" "HTTPS"
        homeLab.tailscale -> homeLab.codeServer "Funnel: public HTTPS -> code-server for work-PC access" "HTTPS"
        homeLab.coredns -> homeLab.k3sServer "Forwards cluster.local queries into k3s" "DNS 53"

        // Platform orchestration
        homeLab.k3sServer -> homeLab.k3sAgent01 "Schedules pods" "HTTPS 10250"
        homeLab.k3sServer -> homeLab.k3sAgent02 "Schedules pods" "HTTPS 10250"

        // Application -> Data
        homeLab.workflows -> homeLab.postgres "Job state" "TCP 5432"
        homeLab.workflows -> homeLab.minio "Artifacts" "S3"
        homeLab.workflows -> homeLab.redis "Queue + rate limiting" "RESP TCP 6379"
        homeLab.modelServer -> homeLab.minio "Model artifacts + inference logs" "S3"
        homeLab.modelServer -> homeLab.postgres "Request + result metadata" "TCP 5432"
        homeLab.vaultwarden -> homeLab.postgres "Encrypted vault blobs" "TCP 5432"

        // Application -> Platform
        homeLab.devtools -> homeLab.k3sServer "Applies manifests" "kubectl/API 6443"
        homeLab.workflows -> homeLab.k3sServer "Deploys workloads" "kubectl/API 6443"

        // Observability (trimmed to the essential edges)
        homeLab.prometheus -> homeLab.minio "Long-term metric storage (remote write)" "S3"
        homeLab.grafana -> homeLab.prometheus "Queries metrics" "HTTP"
        homeLab.grafana -> homeLab.loki "Queries logs" "HTTP"
        homeLab.loki -> homeLab.minio "Log chunk storage" "S3"

        // Backups
        homeLab.restic -> homeLab.postgres "Reads pg_dump snapshots" "TCP 5432"
        homeLab.restic -> homeLab.minio "Backup repository" "S3"

        // --- Deployment environment (Infrastructure layer) -------------------
        deploymentEnvironment "Stage 1 (current)" {

            physical = deploymentNode "Physical Windows host" "Desktop PC" {
                tags "Hardware"

                hyperv = deploymentNode "Windows 11 + Hyper-V" "Hypervisor" {
                    tags "Hypervisor"

                    lvSwitch = deploymentNode "Lab vSwitch · Internal · 192.168.100.0/24 · Windows NAT" "Virtual network" {
                        tags "Network"

                        gatewayVM = deploymentNode "lab-gateway VM (.201)" "Ubuntu 24.04" {
                            tags "VM"

                            systemdGW = deploymentNode "systemd" "Init + service manager" {
                                containerInstance homeLab.tailscale
                            }
                            kernelGW = deploymentNode "Linux kernel" "netfilter" {
                                containerInstance homeLab.iptables
                                containerInstance homeLab.ufw
                            }
                            dockerGW = deploymentNode "Docker engine" "containerd + Docker daemon" {
                                tags "ContainerRuntime"
                                containerInstance homeLab.coredns
                                containerInstance homeLab.nginx
                            }
                        }

                        cpVM = deploymentNode "lab-k3s-controlplane VM (.202)" "Ubuntu 24.04" {
                            tags "VM"
                            containerInstance homeLab.k3sServer
                        }

                        n1VM = deploymentNode "lab-k3s-node01 VM (.203)" "Ubuntu 24.04" {
                            tags "VM"
                            containerInstance homeLab.k3sAgent01
                        }

                        n2VM = deploymentNode "lab-k3s-node02 VM (.204)" "Ubuntu 24.04" {
                            tags "VM"
                            containerInstance homeLab.k3sAgent02
                        }

                        dsVM = deploymentNode "lab-datastore VM (.205)" "Ubuntu 24.04" {
                            tags "VM"
                            dockerDS = deploymentNode "Docker engine" "containerd + Docker daemon" {
                                tags "ContainerRuntime"
                                containerInstance homeLab.postgres
                                containerInstance homeLab.minio
                                containerInstance homeLab.redis
                                containerInstance homeLab.vaultwarden
                                containerInstance homeLab.restic
                            }
                        }

                        aiVM = deploymentNode "lab-ai-ops VM (.206)" "Ubuntu 24.04" {
                            tags "VM"
                            dockerAI = deploymentNode "Docker engine" "containerd + Docker daemon" {
                                tags "ContainerRuntime"
                                containerInstance homeLab.prometheus
                                containerInstance homeLab.grafana
                                containerInstance homeLab.loki
                                containerInstance homeLab.modelServer
                            }
                        }

                        autoVM = deploymentNode "lab-automation VM (.207)" "Ubuntu 24.04" {
                            tags "VM"
                            dockerAuto = deploymentNode "Docker engine" "containerd + Docker daemon" {
                                tags "ContainerRuntime"
                                containerInstance homeLab.workflows
                            }
                        }

                        peVM = deploymentNode "lab-platform-eng VM (.208)" "Ubuntu 24.04" {
                            tags "VM"
                            dockerPE = deploymentNode "Docker engine" "containerd + Docker daemon" {
                                tags "ContainerRuntime"
                                containerInstance homeLab.devtools
                                containerInstance homeLab.structurizr
                                containerInstance homeLab.codeServer
                            }
                        }
                    }
                }
            }
        }
    }

    views {

        systemContext homeLab "SystemContext" "Who uses the lab and what it connects to externally" {
            include *
            autoLayout lr 400 200
        }

        container homeLab "Containers" "Layered architecture. Layer shown by color, runtime by shape (hexagon = Docker, rounded = native, tab = kernel)." {
            include *
            autoLayout tb 400 200
        }

        deployment homeLab "Stage 1 (current)" "Stage1Deployment" "Infrastructure layer: where each container physically runs." {
            include *
            autoLayout tb 400 200
        }

        styles {
            // ---- People and external systems -------------------------------
            element "Person" {
                shape person
                background "#1168bd"
                color "#ffffff"
                fontSize 22
            }
            element "External" {
                shape roundedBox
                background "#546e7a"
                color "#ffffff"
            }
            element "Software System" {
                background "#08427b"
                color "#ffffff"
            }

            // ---- Container styles (one tag = full visual style)
            // Edge layer: orange. Hexagon = Docker, RoundedBox = native daemon.
            element "EdgeDocker" {
                shape hexagon
                background "#f57c00"
                color "#ffffff"
            }
            element "EdgeNative" {
                shape roundedBox
                background "#f57c00"
                color "#ffffff"
            }

            // Application layer: blue.
            element "AppDocker" {
                shape hexagon
                background "#1976d2"
                color "#ffffff"
            }
            element "AppPlanned" {
                shape hexagon
                background "#90caf9"
                color "#0d47a1"
                border dashed
            }

            // Platform layer: purple. k3s runs native.
            element "PlatformNative" {
                shape roundedBox
                background "#6a1b9a"
                color "#ffffff"
            }

            // Data layer: green.
            element "DataDocker" {
                shape hexagon
                background "#2e7d32"
                color "#ffffff"
            }
            element "DataPlanned" {
                shape hexagon
                background "#a5d6a7"
                color "#1b5e20"
                border dashed
            }

            // Security layer: red. iptables/ufw are kernel features.
            element "SecurityKernel" {
                shape component
                background "#c62828"
                color "#ffffff"
            }

            // Observability layer: teal.
            element "ObsDocker" {
                shape hexagon
                background "#00838f"
                color "#ffffff"
            }
            element "ObsPlanned" {
                shape hexagon
                background "#80deea"
                color "#006064"
                border dashed
            }

            // ---- Deployment view chrome (neutral so layer colors pop inside)
            element "Hardware" {
                shape roundedBox
                background "#212121"
                color "#ffffff"
            }
            element "Hypervisor" {
                shape roundedBox
                background "#37474f"
                color "#ffffff"
            }
            element "Network" {
                shape roundedBox
                background "#eceff1"
                color "#212121"
            }
            element "VM" {
                shape roundedBox
                background "#455a64"
                color "#ffffff"
            }
            element "ContainerRuntime" {
                shape roundedBox
                background "#607d8b"
                color "#ffffff"
            }
        }
    }
}
