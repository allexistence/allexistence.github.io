---
# the default layout is 'page'
icon: fas fa-info-circle
order: 4
---

{% capture prompt %}<span class="term-prompt">rishabh@allexistence:<span class="term-path">~</span><span class="term-sigil">$</span></span>{% endcapture %}

<div class="term-window" role="region" aria-label="About me">
  <div class="term-titlebar" aria-hidden="true">
    <span class="term-dot red"></span>
    <span class="term-dot yellow"></span>
    <span class="term-dot green"></span>
    <span class="term-title">rishabh@allexistence: ~</span>
  </div>
  <div class="term-body">
    <div class="term-line" style="--i:0">{{ prompt }}<span class="term-cmd">whoami</span></div>
    <div class="term-out" style="--i:1">Rishabh — Senior Platform Engineer at Srijan: A Material+ Company, Singapore</div>
    <div class="term-line" style="--i:2">{{ prompt }}<span class="term-cmd">cat about.txt</span></div>
    <div class="term-out" style="--i:3">I write about platform engineering, Kubernetes, and AI/ML infrastructure. This blog is where I dig into the layers — depth over abstraction. Expect hands-on notes from real upgrades, migrations, and outages, not just theory.</div>
    <div class="term-line" style="--i:4">{{ prompt }}<span class="term-cmd">ls ~/stack/*</span></div>
    <div class="term-out" style="--i:5">
      <div class="term-group"><span class="term-head">~/stack/kubernetes-platform:</span><br><span class="term-dir">rke2/</span>&nbsp;&nbsp;<span class="term-dir">rancher/</span>&nbsp;&nbsp;<span class="term-dir">aws-eks/</span>&nbsp;&nbsp;<span class="term-dir">vmware-tanzu-tkgm/</span>&nbsp;&nbsp;<span class="term-dir">vsphere-with-tanzu/</span>&nbsp;&nbsp;<span class="term-dir">kubevirt/</span>&nbsp;&nbsp;<span class="term-dir">cilium/</span>&nbsp;&nbsp;<span class="term-dir">harbor-registry/</span></div>
      <div class="term-group"><span class="term-head">~/stack/virtualisation-cloud:</span><br><span class="term-dir">suse-harvester-hci/</span>&nbsp;&nbsp;<span class="term-dir">vmware-vsphere-day2/</span>&nbsp;&nbsp;<span class="term-dir">aws/</span>&nbsp;&nbsp;<span class="term-dir">azure/</span></div>
      <div class="term-group"><span class="term-head">~/stack/ai-gpu-infra:</span><br><span class="term-dir">gpu-pcie-passthrough/</span>&nbsp;&nbsp;<span class="term-dir">iommu/</span>&nbsp;&nbsp;<span class="term-dir">nvidia-gpu-operator/</span>&nbsp;&nbsp;<span class="term-dir">ai-inference/</span></div>
      <div class="term-group"><span class="term-head">~/stack/iac-automation:</span><br><span class="term-dir">terraform/</span>&nbsp;&nbsp;<span class="term-dir">packer/</span>&nbsp;&nbsp;<span class="term-dir">python/</span></div>
      <div class="term-group"><span class="term-head">~/stack/cicd-gitops:</span><br><span class="term-dir">jenkins/</span>&nbsp;&nbsp;<span class="term-dir">gitlab-ci/</span>&nbsp;&nbsp;<span class="term-dir">argo-cd/</span></div>
      <div class="term-group"><span class="term-head">~/stack/observability:</span><br><span class="term-dir">prometheus/</span>&nbsp;&nbsp;<span class="term-dir">grafana/</span>&nbsp;&nbsp;<span class="term-dir">elk-efk/</span></div>
    </div>
    <div class="term-line" style="--i:6">{{ prompt }}<span class="term-cmd">kubectl get engineer rishabh</span></div>
    <div class="term-out term-nowrap" style="--i:7"><span class="term-head">NAME&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;ROLE&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;EXPERIENCE&nbsp;&nbsp;&nbsp;STATUS</span><br>rishabh&nbsp;&nbsp;&nbsp;platform-engineer&nbsp;&nbsp;&nbsp;7y+&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<span class="term-ok">Running</span></div>
    <div class="term-line" style="--i:8">{{ prompt }}<span class="term-cmd">./contact --list</span></div>
    <div class="term-out term-nowrap" style="--i:9">github&nbsp;&nbsp;&nbsp;&nbsp;→&nbsp;<a href="https://github.com/allexistence" target="_blank" rel="noopener noreferrer">github.com/allexistence</a><br>linkedin&nbsp;&nbsp;→&nbsp;<a href="https://www.linkedin.com/in/imrishabh27" target="_blank" rel="noopener noreferrer">linkedin.com/in/imrishabh27</a><br>rss&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;→&nbsp;<a href="{{ '/feed.xml' | relative_url }}">/feed.xml</a></div>
    <div class="term-line" style="--i:10">{{ prompt }}<span class="term-cursor" aria-hidden="true"></span></div>
  </div>
</div>
