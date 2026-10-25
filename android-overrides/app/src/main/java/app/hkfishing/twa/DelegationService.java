package app.hkfishing.twa;

// Replaces the Bubblewrap-generated DelegationService: registers HkLocationHandler
// instead of com.google.androidbrowserhelper.locationdelegation.LocationDelegationExtraCommandHandler.
public class DelegationService extends
        com.google.androidbrowserhelper.trusted.DelegationService {
    @Override
    public void onCreate() {
        super.onCreate();
        registerExtraCommandHandler(new HkLocationHandler());
    }
}
