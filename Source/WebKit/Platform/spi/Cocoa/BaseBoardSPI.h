// MAVERICKS_BACKPORT: empty placeholder header so the non-internal-SDK `#import "BaseBoardSPI.h"` in BackBoardServicesSPI.h / WKWebsiteDataStore.mm / WebPushDaemon.mm resolves on 10.9, where the iOS BaseBoard SPI does not exist (all real declarations are guarded out on Mac).
#pragma once
