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
 *   Infrastructure layer    (shown in the deployment view: hardware, Hyper-V,
 *                           Lab vSwitch, VMs, Docker engine)
 *
 * Modeling conventions:
 *   - Each SERVICE is a C4 container. Most deploy as Docker containers (the
 *     "technology" field names the image); a few are native systemd units
 *     (tailscale, k3s); two are kernel features (iptables, ufw).
 *   - Groups in the container view map one-to-one to architectural layers.
 *   - Runtime (Docker / Native / Kernel) drives color + shape via tags.
 *   - Infrastructure layer is the deployment view (VMs on Hyper-V on a
 *     Windows host), not a container group, because deployment nodes model
 *     that layer better in C4.
 *
 * Rendering:
 *   - Zero-install : https://structurizr.com/dsl or https://playground.structurizr.com
 *   - Local Docker : docker run -it --rm -p 8080:8080 \
 *                      -v "${PWD}:/usr/local/structurizr" structurizr/lite
 *   - VS Code      : install the "Structurizr DSL" extension (ciarant)
 * =============================================================================
 */

workspace "Home Lab" "Layered Ubuntu/Hyper-V lab on a Windows host: edge, application, platform, data, security, and observability layers, mostly deployed as Docker containers." {

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

            // ---------------------------------------------------------------
            // Edge & Access layer
            //   Where traffic enters the lab. Remote access (tailscale),
            //   internal DNS (coredns), public-facing reverse proxy (nginx).
            // ---------------------------------------------------------------
            group "Edge and Access layer" {
                tailscale = container "Tailscale" "Subnet router, exposes 192.168.100.0/24 to the tailnet; remote admin SSH" "Go · systemd" {
                    tags "Native,Layer-Edge"
                }
                coredns = container "CoreDNS" "Authoritative for *.lab.local, forwards the rest to 1.1.1.1 / 8.8.8.8, served via Tailscale Split DNS to the tailnet" "Docker: coredns/coredns:1.11.3" {
                    tags "Docker,Layer-Edge"
                }
                nginx = container "nginx" "Reverse proxy for internal lab services (*.lab.local → service backends)" "Docker: nginx:alpine" {
                    tags "Docker,Planned,Layer-Edge"
                }
            }

            // ---------------------------------------------------------------
            // Application layer
            //   The services the operator and users actually consume. Runs
            //   workloads, workflows, and tooling.
            // ---------------------------------------------------------------
            group "Application layer" {
                workflows = container "Workflow runner" "Scheduled jobs, CI agents, operational automation" "Docker: (TBD)" {
                    tags "Docker,Planned,Layer-App"
                }
                devtools = container "Platform tools" "IaC runners, templating, internal CLI sandbox" "Docker: (TBD)" {
                    tags "Docker,Planned,Layer-App"
                }
                modelServer = container "Model serving" "AI/ML model inference endpoint" "Docker: (TBD)" {
                    tags "Docker,Planned,Layer-App"
                }
                structurizr = container "Structurizr Lite" "Self-hosted renderer for this workspace.dsl. Makes the architecture diagrams available at arch.lab.local so the lab documents itself." "Docker: structurizr/lite" {
                    tags "Docker,Planned,Layer-App,SelfDocumenting"
                }
            }

            // ---------------------------------------------------------------
            // Platform layer
            //   Orchestration and runtime. k3s is the Kubernetes distribution
            //   hosting application workloads (over time, more of the app
            //   layer will migrate from Docker-on-VM to k3s pods).
            // ---------------------------------------------------------------
            group "Platform layer" {
                k3sServer = container "k3s server" "Kubernetes API, scheduler, controller-manager, embedded etcd" "Go · systemd" {
                    tags "Native,Planned,Layer-Platform"
                }
                k3sAgent01 = container "k3s agent (node01)" "kubelet + containerd; hosts workload pods" "Go · systemd" {
                    tags "Native,Planned,Layer-Platform"
                }
                k3sAgent02 = container "k3s agent (node02)" "kubelet + containerd; hosts workload pods" "Go · systemd" {
                    tags "Native,Planned,Layer-Platform"
                }
            }

            // ---------------------------------------------------------------
            // Data layer
            //   Stateful services. Separated from the application layer so
            //   that apps can be rebuilt freely without data risk.
            // ---------------------------------------------------------------
            group "Data layer" {
                postgres = container "PostgreSQL" "Primary OLTP store for application data" "Docker: postgres:16" {
                    tags "Docker,Planned,Layer-Data"
                }
                minio = container "MinIO" "S3-compatible object storage for blobs, logs, artifacts" "Docker: minio/minio" {
                    tags "Docker,Planned,Layer-Data"
                }
                restic = container "restic" "Encrypted backups of Postgres and critical volumes to MinIO and offsite" "Docker: restic/restic" {
                    tags "Docker,Planned,Layer-Data"
                }
            }

            // ---------------------------------------------------------------
            // Security layer (cross-cutting)
            //   Firewall and NAT enforcement. Cross-cutting because policies
            //   apply across all other layers.
            // ---------------------------------------------------------------
            group "Security layer (cross-cutting)" {
                iptables = container "iptables NAT" "Masquerades lab egress from 192.168.100.0/24 through eth1 on the home network" "Kernel netfilter" {
                    tags "Kernel,Layer-Security"
                }
                ufw = container "ufw" "Per-host firewall policy across every lab VM" "Kernel netfilter" {
                    tags "Kernel,Planned,Layer-Security"
                }
            }

            // ---------------------------------------------------------------
            // Observability layer (cross-cutting)
            //   Metrics, logs, dashboards. Cross-cutting because every other
            //   layer emits signals consumed here.
            // ---------------------------------------------------------------
            group "Observability layer (cross-cutting)" {
                prometheus = container "Prometheus" "Scrapes metrics from every layer; long-term storage via MinIO" "Docker: prom/prometheus" {
                    tags "Docker,Planned,Layer-Observability"
                }
                grafana = container "Grafana" "Dashboards over Prometheus and Loki" "Docker: grafana/grafana" {
                    tags "Docker,Planned,Layer-Observability"
                }
                loki = container "Loki" "Log aggregation with chunk storage in MinIO" "Docker: grafana/loki" {
                    tags "Docker,Planned,Layer-Observability"
                }
            }
        }

        // --- Relationships ----------------------------------------------------
        // Dependency direction reflects the layered architecture. Higher
        // layers depend on lower ones. Cross-cutting layers (security,
        // observability) have edges into many layers but are rarely called
        // by them.

        // Operator paths
        operator -> tailnet "Connects remotely via" "Tailscale client"
        operator -> homeLab.tailscale "Remote admin over SSH" "SSH via Tailscale"

        // External routing
        tailnet -> homeLab.tailscale "Exposes lab subnet" "Subnet router"
        homeLab.iptables -> homeNet "NAT egress via eth1" "IPv4"
        homeNet -> internet "WAN"

        // Edge layer into application + platform
        homeLab.tailscale -> homeLab.iptables "Delivers tailnet traffic into the lab" "routes"
        homeLab.nginx -> homeLab.k3sServer "Proxies *.lab.local to k3s ingress" "HTTPS"
        homeLab.nginx -> homeLab.grafana "Proxies grafana.lab.local" "HTTPS"
        homeLab.nginx -> homeLab.minio "Proxies s3.lab.local" "HTTPS"
        homeLab.nginx -> homeLab.structurizr "Proxies arch.lab.local" "HTTPS"
        operator -> homeLab.structurizr "Views lab architecture" "browser"
        homeLab.coredns -> homeLab.k3sServer "Forwards cluster.local queries" "DNS 53"

        // Platform orchestration (internal to platform layer)
        homeLab.k3sServer -> homeLab.k3sAgent01 "Schedules pods" "HTTPS 10250"
        homeLab.k3sServer -> homeLab.k3sAgent02 "Schedules pods" "HTTPS 10250"

        // Application → Data
        homeLab.workflows -> homeLab.postgres "Job state" "TCP 5432"
        homeLab.workflows -> homeLab.minio "Artifacts" "S3"
        homeLab.modelServer -> homeLab.minio "Reads models + writes inference logs" "S3"
        homeLab.modelServer -> homeLab.postgres "Request + result metadata" "TCP 5432"
        homeLab.devtools -> homeLab.k3sServer "Applies manifests" "kubectl/API 6443"

        // Application → Platform
        homeLab.workflows -> homeLab.k3sServer "Deploys/runs workloads" "kubectl/API 6443"

        // Observability (cross-cutting: scrapes all layers)
        homeLab.prometheus -> homeLab.tailscale "Scrapes tailscale metrics" "HTTP"
        homeLab.prometheus -> homeLab.k3sServer "Scrapes kube-state-metrics, kubelets" "HTTPS"
        homeLab.prometheus -> homeLab.k3sAgent01 "Scrapes kubelet + node_exporter" "HTTPS"
        homeLab.prometheus -> homeLab.k3sAgent02 "Scrapes kubelet + node_exporter" "HTTPS"
        homeLab.prometheus -> homeLab.postgres "Scrapes postgres_exporter" "HTTP"
        homeLab.prometheus -> homeLab.minio "Scrapes MinIO metrics endpoint" "HTTP"
        homeLab.prometheus -> homeLab.minio "Long-term metric storage (remote write)" "S3"
        homeLab.grafana -> homeLab.prometheus "Queries metrics" "HTTP"
        homeLab.grafana -> homeLab.loki "Queries logs" "HTTP"
        homeLab.loki -> homeLab.minio "Log chunk storage" "S3"

        // Backups (data layer internal)
        homeLab.restic -> homeLab.postgres "Reads snapshots" "pg_dump"
        homeLab.restic -> homeLab.minio "Backup repository" "S3"

        // --- Deployment environment (Infrastructure layer) -------------------
        // This view models the Infrastructure layer: hardware, hypervisor,
        // virtual networking, VMs, Docker engine, and service placement.
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
            autoLayout lr
        }

        container homeLab "Containers" "Layered architecture view. Groups map to layers: Edge & Access, Application, Platform, Data, Security (cross-cutting), Observability (cross-cutting)." {
            include *
            autoLayout tb
        }

        deployment homeLab "Stage 1 (current)" "Stage1Deployment" "Infrastructure layer: where each container physically runs. Docker engine shown as a deployment node inside VMs that use Docker; systemd and Linux kernel for native and kernel services." {
            include *
            autoLayout tb
        }

        styles {
            element "Person" {
                shape person
                background "#1168bd"
                color "#ffffff"
            }
            element "External" {
                background "#777777"
                color "#ffffff"
            }
            element "Software System" {
                background "#08427b"
                color "#ffffff"
            }
            element "Container" {
                background "#438dd5"
                color "#ffffff"
            }
            element "Docker" {
                background "#1976d2"
                color "#ffffff"
                shape hexagon
            }
            element "Native" {
                background "#558b2f"
                color "#ffffff"
                shape roundedBox
            }
            element "Kernel" {
                background "#455a64"
                color "#ffffff"
                shape roundedBox
            }
            element "Planned" {
                border dashed
            }
            element "VM" {
                background "#0277bd"
                color "#ffffff"
                shape roundedBox
            }
            element "ContainerRuntime" {
                background "#1565c0"
                color "#ffffff"
            }
            element "Hypervisor" {
                background "#01579b"
                color "#ffffff"
            }
            element "Hardware" {
                background "#263238"
                color "#ffffff"
                shape roundedBox
            }
            element "Network" {
                background "#fff3e0"
                color "#000000"
            }
        }

        theme default
    }
}
