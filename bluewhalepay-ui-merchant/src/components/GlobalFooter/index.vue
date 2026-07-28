<template>
  <global-footer class="footer custom-render">
    <template v-slot:links></template>
    <template v-slot:copyright>
      Copyright © 2023
      <a href="http://www.bluewhalepay.com" target="_blank">bluewhalepay.com</a>
      . All rights reserved.
    </template>
  </global-footer>
</template>

<script>
export default {
  name: 'ProGlobalFooter',
}
</script>
