'use strict';
function isProfileManaged(lane) {
  return lane?.profileManaged !== undefined && lane.profileManaged !== false;
}
module.exports = { isProfileManaged };
