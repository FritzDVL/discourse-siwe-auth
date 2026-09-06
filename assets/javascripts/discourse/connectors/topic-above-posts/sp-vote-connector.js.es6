export default {
  setupComponent(args, component) {
    const siteSettings = component.siteSettings || {}
    if (!siteSettings.siwe_voting_enabled) {
      component.set('isGovernanceTopic', false)
      return
    }

    const tag = siteSettings.siwe_voting_tag || 'governance'
    const topic = args.model || component.get('model') || {}
    const tags = topic.tags || []
    component.set('isGovernanceTopic', tags.includes(tag))
  },
}
